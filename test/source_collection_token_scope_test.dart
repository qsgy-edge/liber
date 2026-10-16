import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';

import 'native_library.dart';

const _origin = 'https://collection-scope.test';

class _Pages implements BookSourceTransport {
  _Pages(this.pages);
  final Map<String, String> pages;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async =>
      pages[Uri.parse(path).path] ??
      (throw StateError('Unexpected request: $path'));
}

Future<String> _author(
  String script, {
  bool json = false,
  String library = '',
  String loginCheck = '',
}) async {
  final source = <String, dynamic>{
    'bookSourceUrl': _origin,
    if (library.isNotEmpty) 'jsLib': library,
    if (loginCheck.isNotEmpty) 'loginCheckJs': loginCheck,
    'ruleBookInfo': {
      'name': '',
      'author': '@js:$script',
      'tocUrl': '@js:"/toc"',
    },
    'ruleToc': {
      'chapterList': json ? r'$.items' : 'a',
      'chapterName': json ? r'$.name' : 'a@text',
      'chapterUrl': json ? r'$.url' : 'a@href',
    },
  };
  final pages = _Pages({
    '/book': json
        ? '{"items":[{"name":"A"},{"name":"B"}]}'
        : '<article>book</article>',
    '/toc': json
        ? '{"items":[{"name":"chapter","url":"/chapter"}]}'
        : '<a href="/chapter">chapter</a>',
  });
  final BookSourcePipeline pipeline = json
      ? JsonSourcePipeline(source, pages)
      : HtmlSourcePipeline(source, pages);
  try {
    final (book, _) = await pipeline.details(
      HtmlBook(url: Uri.parse('$_origin/book'), title: 'retained'),
    );
    return book.author;
  } finally {
    pipeline.cancel();
  }
}

Future<Object?> _run(
  InProcessSourceScriptRuntime runtime,
  String script, {
  Map<String, Object?> input = const {},
}) => runtime.evaluate(
  source: script,
  input: {'sourceKey': _origin, ...input},
  timeout: const Duration(seconds: 5),
);

void main() {
  setUpAll(
    () => InProcessSourceScriptRuntime.initialize(
      libraryPath: nativeLibraryPath(),
    ),
  );
  tearDownAll(InProcessSourceScriptRuntime.dispose);

  // Actual session-wrapper/library controls, not frozen Java scope goldens.
  group('source collection token scope', () {
    test('ordinary HTML evaluation has no transport token binding', () async {
      expect(
        jsonDecode(
          await _author(
            'JSON.stringify([typeof collectionToken,typeof __elementsResult])',
          ),
        ),
        ['undefined', 'undefined'],
      );
    });

    test(
      'ordinary JSON evaluation hides token and keeps plain element values',
      () async {
        expect(
          jsonDecode(
            await _author(
              r'var es=java.getElements("$.items"); '
              'JSON.stringify([typeof collectionToken,es,typeof es.select])',
              json: true,
            ),
          ),
          [
            'undefined',
            [
              {'name': 'A'},
              {'name': 'B'},
            ],
            'undefined',
          ],
        );
      },
    );

    test(
      'library lookup hides token while retaining shared session state',
      () async {
        const library =
            'let repairScopeCalls=0; '
            'function repairScopeProbe(){return [typeof collectionToken,++repairScopeCalls];}';
        for (final count in [1, 2]) {
          final runtime = InProcessSourceScriptRuntime(jsLib: library);
          final value = await _run(
            runtime,
            'JSON.stringify([typeof collectionToken,repairScopeProbe()])',
          );
          expect(jsonDecode(value as String), [
            'undefined',
            ['undefined', count],
          ]);
        }
      },
    );

    test(
      'HTML login check hides token with result normalization disabled',
      () async {
        final author = await _author(
          '"checked"',
          library:
              'function repairLoginProbe(){return typeof collectionToken;}',
          loginCheck:
              'if(typeof collectionToken!=="undefined" || '
              'repairLoginProbe()!=="undefined" || '
              'typeof __elementsResult!=="undefined") '
              'throw new Error("transport token leaked into login check"); '
              'if(typeof result.body!=="function" || typeof result.url!=="function") '
              'throw new Error("lost response methods"); result',
        );
        expect(author, 'checked');
      },
    );

    test(
      'library and input owned token names retain lookup and state lifetime',
      () async {
        const library =
            'let collectionToken="library-owned"; '
            'let repairOwnedCalls=0; '
            'function repairOwnedProbe(){return [collectionToken,++repairOwnedCalls];}';
        for (final (count, inputName) in <(int, String?)>[
          (1, null),
          (2, 'input-owned'),
          (3, null),
        ]) {
          final runtime = InProcessSourceScriptRuntime(jsLib: library);
          final value = await _run(
            runtime,
            'JSON.stringify([collectionToken,repairOwnedProbe()])',
            input: {'collectionToken': ?inputName},
          );
          expect(jsonDecode(value as String), [
            inputName ?? 'library-owned',
            ['library-owned', count],
          ]);
        }
      },
    );

    test('source owned lexical token name remains available', () async {
      final runtime = InProcessSourceScriptRuntime();
      expect(
        await _run(
          runtime,
          'const collectionToken="script-owned"; collectionToken',
        ),
        'script-owned',
      );
    });
  });
}
