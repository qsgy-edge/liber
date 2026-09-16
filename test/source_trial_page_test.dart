import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/source_trial_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

void main() {
  testWidgets(
    'source trial reports unsupported rules without a success result',
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
                  'ruleSearch': {'bookList': '@js:result'},
                },
              ),
            ],
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'test');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.textContaining('试读失败'), findsOneWidget);
      expect(find.text('请求记录'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
