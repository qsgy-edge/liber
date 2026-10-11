import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/main.dart' as application;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'temp_directory.dart';

const _nonWindows = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.linux,
  TargetPlatform.macOS,
});
const _supported = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.linux,
  TargetPlatform.macOS,
  TargetPlatform.windows,
});

void main() {
  late Directory scratch;
  late Directory support;
  late Directory windows;
  late PathProviderPlatform originalProvider;
  late _PathProvider provider;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('liber-startup-');
    support = Directory('${scratch.path}/application-support');
    windows = Directory('${scratch.path}/windows-default');
    originalProvider = PathProviderPlatform.instance;
    provider = _PathProvider(() async => support.path);
    PathProviderPlatform.instance = provider;
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalProvider;
    await deleteTempDirectory(scratch);
  });

  // Intercept only the legacy Windows directory constructor. This keeps even
  // the pre-fix non-Windows startup regression away from the operator's data.
  Future<void> inScratch(WidgetTester tester, Future<void> Function() body) =>
      tester.runAsync(() {
        final parent = Zone.current;
        final appData = Platform.environment['APPDATA'];
        return IOOverrides.runZoned(
          () async {
            try {
              await body();
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
            }
          },
          createDirectory: (path) =>
              path == '$appData${Platform.pathSeparator}Liber'
              ? windows
              : parent.run(() => Directory(path)),
        );
      });

  testWidgets(
    'default startup creates and reopens the platform support workspace',
    (tester) async {
      await inScratch(tester, () async {
        await tester.pumpWidget(
          const application.LiberApp(interfaceLanguage: Locale('en')),
        );
        await _waitForStartup(tester);
        expect(provider.calls, 1);
        expect(await File('${support.path}/manifest.json').exists(), isTrue);
        expect(
          await File('${support.path}/spaces/default/data.db').exists(),
          isTrue,
        );
        expect(await Directory('${support.path}/Liber').exists(), isFalse);
        expect(await windows.exists(), isFalse);
        final manifest = await File(
          '${support.path}/manifest.json',
        ).readAsString();

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          const application.LiberApp(interfaceLanguage: Locale('en')),
        );
        await _waitForStartup(tester);
        expect(provider.calls, 2);
        expect(
          await File('${support.path}/manifest.json').readAsString(),
          manifest,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
    variant: _nonWindows,
  );

  testWidgets(
    'Windows keeps APPDATA/Liber and bypasses the plugin',
    (tester) async {
      await inScratch(tester, () async {
        provider.resolve = () async =>
            throw StateError('must not look up support');
        await tester.pumpWidget(
          const application.LiberApp(interfaceLanguage: Locale('en')),
        );
        if (Platform.environment['APPDATA'] == null) {
          await _showMigration(tester);
          await _waitForText(tester, 'APPDATA is unavailable');
        } else {
          await _waitForStartup(tester);
          expect(await File('${windows.path}/manifest.json').exists(), isTrue);
          expect(
            await File('${windows.path}/spaces/default/data.db').exists(),
            isTrue,
          );
        }
        expect(provider.calls, 0);
        expect(await support.exists(), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('explicit widget root bypasses platform lookup', (tester) async {
    await inScratch(tester, () async {
      provider.resolve = () async =>
          throw StateError('must not look up support');
      final explicit = Directory('${scratch.path}/explicit');
      await tester.pumpWidget(
        application.LiberApp(
          workspaceRoot: explicit,
          interfaceLanguage: const Locale('en'),
        ),
      );
      await _waitForStartup(tester);
      expect(provider.calls, 0);
      expect(await File('${explicit.path}/manifest.json').exists(), isTrue);
      expect(
        await File('${explicit.path}/spaces/default/data.db').exists(),
        isTrue,
      );
      expect(await support.exists(), isFalse);
      expect(await windows.exists(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }, variant: _supported);

  testWidgets(
    'pending platform lookup leaves the first frame responsive',
    (tester) async {
      await inScratch(tester, () async {
        final pending = Completer<String?>();
        provider.resolve = () => pending.future;
        await tester.pumpWidget(
          const application.LiberApp(interfaceLanguage: Locale('en')),
        );
        await tester.pump();
        expect(provider.calls, 1);
        expect(find.byType(NavigationRail), findsOneWidget);
        expect(_languageButton(tester).onPressed, isNull);
        await _showMigration(tester);
        expect(find.text('Opening…'), findsOneWidget);
        pending.complete(support.path);
        await _waitForStartup(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
    variant: _nonWindows,
  );

  for (final missing in [false, true]) {
    testWidgets(
      missing
          ? 'missing support directory shows startup error'
          : 'platform lookup failure shows startup error',
      (tester) async {
        await inScratch(tester, () async {
          provider.resolve = () async {
            if (missing) return null;
            throw StateError('support directory unavailable');
          };
          await tester.pumpWidget(
            const application.LiberApp(interfaceLanguage: Locale('en')),
          );
          await _showMigration(tester);
          await _waitForText(tester, 'The space store is unavailable:');
          expect(provider.calls, 1);
          expect(
            find.textContaining(
              missing
                  ? 'Unable to get application support directory'
                  : 'support directory unavailable',
            ),
            findsOneWidget,
          );
          expect(_languageButton(tester).onPressed, isNull);
          expect(await support.exists(), isFalse);
          expect(await windows.exists(), isFalse);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      },
      variant: _nonWindows,
    );
  }

  // A second CLI invocation supplies the define and exercises the production
  // entrypoint. Normal suite runs skip this row instead of inventing a path.
  const definedRoot = String.fromEnvironment('LIBER_WORKSPACE_ROOT');
  testWidgets(
    'production entrypoint honors LIBER_WORKSPACE_ROOT',
    (tester) async {
      await inScratch(tester, () async {
        final explicit = Directory(definedRoot);
        expect(
          await explicit.exists(),
          isFalse,
          reason: 'This row requires a fresh scratch directory.',
        );
        addTearDown(() => deleteTempDirectory(explicit));
        provider.resolve = () async =>
            throw StateError('must not look up support');
        application.main();
        await tester.pump();
        await _waitForStartup(tester);
        expect(provider.calls, 0);
        expect(
          jsonDecode(
            await File('${explicit.path}/manifest.json').readAsString(),
          ),
          isMap,
        );
        expect(
          await File('${explicit.path}/spaces/default/data.db').exists(),
          isTrue,
        );
        expect(await support.exists(), isFalse);
        expect(await windows.exists(), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
    variant: _supported,
    skip: definedRoot.isEmpty,
  );
}

class _PathProvider extends PathProviderPlatform {
  _PathProvider(this.resolve);

  Future<String?> Function() resolve;
  int calls = 0;

  @override
  Future<String?> getApplicationSupportPath() {
    calls++;
    return resolve();
  }
}

IconButton _languageButton(WidgetTester tester) => tester.widget<IconButton>(
  find.ancestor(
    of: find.byIcon(Icons.language),
    matching: find.byType(IconButton),
  ),
);

Future<void> _showMigration(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.import_export_outlined));
  await tester.pump();
}

Future<void> _waitForStartup(WidgetTester tester) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump();
    if (_languageButton(tester).onPressed != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Startup did not open its space and enable settings.');
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump();
    if (find.textContaining(text).evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(find.textContaining(text), findsOneWidget);
}
