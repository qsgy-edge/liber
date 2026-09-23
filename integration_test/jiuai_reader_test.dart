import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import '../test/l10n_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('jiuai native source search selection and chapter navigation', (
    tester,
  ) async {
    const sourcePath = String.fromEnvironment('LIBER_REVIEW_SOURCE');
    const evidencePath = String.fromEnvironment('LIBER_REVIEW_EVIDENCE');
    final directory = await Directory.systemTemp.createTemp(
      'liber-jiuai-native-',
    );
    final service = ShelfService(
      SpaceStore(SpaceDatabase.file(File('${directory.path}/data.db'))),
    );
    final source =
        jsonDecode(await File(sourcePath).readAsString())
            as Map<String, dynamic>;
    Future<void> settle() => tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 30),
    );
    try {
      await tester.pumpWidget(
        localizedApp(
          home: HtmlSourceBrowser(
            source: source,
            keyword: '回放',
            service: service,
          ),
        ),
      );
      await settle();
      expect(find.text('回放之书'), findsOneWidget);
      expect(find.text('另一本书'), findsOneWidget);
      await tester.tap(find.text('回放之书'));
      await settle();
      expect(find.text('本地回放的书籍简介。'), findsOneWidget);
      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('第二章'), findsOneWidget);
      await tester.tap(find.text('第一章'));
      await settle();
      expect(find.byType(OnlineReaderPage), findsOneWidget);
      expect(find.textContaining('第一页正文。'), findsOneWidget);
      expect(find.textContaining('第二页正文。'), findsOneWidget);
      expect(find.textContaining('不应提取的嵌套广告'), findsNothing);
      await tester.tap(find.text('下一章'));
      await settle();
      // The original replaceRegex removes chapter.title from the fixture text.
      expect(find.text('正文。'), findsOneWidget);
      final saved = await service.lastRead();
      expect(saved!.progress!.chapterIndex, 1, reason: '第二章');
      expect(saved.textOffset, greaterThan(0));
      expect(tester.takeException(), isNull);
      await File(evidencePath).writeAsString(
        jsonEncode({
          'status': 'pass',
          'searchHits': 2,
          'selectedBook': '回放之书',
          'firstChapterPages': 2,
          'savedChapter': '第二章',
          'savedOffset': saved.textOffset,
          'runtimeErrors': 0,
          'oracle': 'not-run',
        }),
      );
      debugPrint('JIUAI_NATIVE_PASS search=2 pages=2 savedChapter=第二章');
    } catch (error) {
      await File(evidencePath).writeAsString(
        jsonEncode({'status': 'fail', 'error': '$error', 'oracle': 'not-run'}),
      );
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox());
      await settle();
      await service.close();
      await directory.delete(recursive: true);
    }
  });
}
