import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/source_trial_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

void main() {
  for (final entered in ['', 'user query']) {
    testWidgets('source check keyword is a fallback only ($entered)', (
      tester,
    ) async {
      final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
      addTearDown(store.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SourceTrialPage(
            service: ShelfService(store),
            sources: const [
              ImportedBookSource(
                id: 'default-keyword',
                data: {
                  'bookSourceName': 'Default keyword',
                  'bookSourceUrl': 'https://example.invalid',
                  'searchUrl': '/search?key={{key}}',
                  'ruleSearch': {
                    'bookList': r'$.items',
                    'name': r'$.name',
                    'bookUrl': r'$.url',
                    'checkKeyWord': '  source query  ',
                    // Stop before networking/native code so the submitted
                    // keyword is what this row observes: a rule field the JSON
                    // adapter refuses by name fails the stage before its first
                    // request.
                    'unsupportedRule': r'$.x',
                  },
                },
              ),
            ],
          ),
        ),
      );
      if (entered.isNotEmpty) {
        await tester.enterText(find.byType(TextField), entered);
      }
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      final browser = tester.widget<HtmlSourceBrowser>(
        find.byType(HtmlSourceBrowser),
      );
      expect(browser.keyword, entered.isEmpty ? '  source query  ' : entered);
      expect(tester.takeException(), isNull);
    });
  }
  for (final declared in <Object>['numeric', 'structured']) {
    testWidgets('source check keyword: a $declared checkKeyWord', (tester) async {
      final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
      addTearDown(store.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SourceTrialPage(
            service: ShelfService(store),
            sources: [
              ImportedBookSource(
                id: 'check-keyword-$declared',
                data: {
                  'bookSourceName': 'Check keyword $declared',
                  'bookSourceUrl': 'https://example.invalid',
                  // Stop before networking/native code; the submitted keyword is
                  // what this row observes.
                  'searchUrl': '/search?key={{key}}',
                  'ruleSearch': {
                    'bookList': r'$.items',
                    'name': r'$.name',
                    'bookUrl': r'$.url',
                    // The frozen reader reads the field through Gson into
                    // `String?`: a scalar is its literal text, and an array or
                    // object is refused while the source is parsed.
                    'checkKeyWord': declared == 'numeric'
                        ? 42
                        : <String, Object>{'nested': 1},
                    'unsupportedRule': r'$.x',
                  },
                },
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      if (declared == 'numeric') {
        expect(
          tester.widget<HtmlSourceBrowser>(find.byType(HtmlSourceBrowser)).keyword,
          '42',
        );
      } else {
        expect(find.byType(HtmlSourceBrowser), findsNothing);
        expect(find.textContaining('读取失败'), findsOneWidget);
        expect(find.textContaining('ruleSearch.checkKeyWord'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a loginUrl/loginCheckJs source opens instead of being refused by name',
    (tester) async {
      final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
      addTearDown(store.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SourceTrialPage(
            service: ShelfService(store),
            sources: const [
              ImportedBookSource(
                id: 'login-fields',
                data: {
                  'bookSourceName': 'Login fields',
                  'bookSourceUrl': 'https://example.invalid',
                  // The fields this product used to refuse before any request
                  // (#59): a source that declares them opens like any other. A
                  // rule field the JSON adapter refuses by name still stops the
                  // stage before its first request, so this row is deterministic
                  // without a network.
                  'loginUrl': 'https://example.invalid/user/login',
                  'loginCheckJs': 'result',
                  'searchUrl': '/search?key={{key}}',
                  'ruleSearch': {
                    'bookList': r'$.items',
                    'name': r'$.name',
                    'bookUrl': r'$.url',
                    'unsupportedRule': r'$.x',
                  },
                },
              ),
            ],
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'test');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(HtmlSourceBrowser), findsOneWidget);
      expect(
        tester.widget<HtmlSourceBrowser>(find.byType(HtmlSourceBrowser)).keyword,
        'test',
      );
      expect(find.textContaining('loginCheckJs'), findsNothing);
      expect(find.textContaining('loginUrl'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source trial opens the browser, where an unsupported field fails without a success result',
    (tester) async {
      final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
      addTearDown(store.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SourceTrialPage(
            service: ShelfService(store),
            sources: const [
              ImportedBookSource(
                id: 'test',
                data: {
                  'bookSourceName': 'Unsupported source',
                  'bookSourceUrl': 'https://example.invalid',
                  // A JSON-shaped rule set sends the source to the JSON adapter,
                  // so the failure below is reached without the native library;
                  // `ruleSearch.unsupportedRule` is the rule this product
                  // refuses by name.
                  'searchUrl': '/search?key={{key}}',
                  'ruleSearch': {
                    'bookList': r'$.items',
                    'name': r'$.name',
                    'bookUrl': r'$.url',
                    'unsupportedRule': r'$.x',
                  },
                },
              ),
            ],
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'test');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(HtmlSourceBrowser), findsOneWidget);
      expect(find.textContaining('读取失败'), findsOneWidget);
      expect(find.textContaining('unsupportedRule'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
