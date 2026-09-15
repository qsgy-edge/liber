import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/migration/migration_service.dart';
import 'package:liber/source/source_trial_page.dart';

void main() {
  testWidgets(
    'source trial reports unsupported rules without a success result',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SourceTrialPage(
            sources: [
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
