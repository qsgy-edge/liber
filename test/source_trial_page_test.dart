import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/source_trial_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

void main() {
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
                  // `loginCheckJs` is the field this product refuses by name.
                  'loginCheckJs': 'true',
                  'searchUrl': '/search?key={{key}}',
                  'ruleSearch': {
                    'bookList': r'$.items',
                    'name': r'$.name',
                    'bookUrl': r'$.url',
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
      expect(find.textContaining('loginCheckJs'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
