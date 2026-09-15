import 'dart:convert';
import 'dart:io';

import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';

Future<void> main() async {
  final source =
      (jsonDecode(await File('book_sources/shudugu.json').readAsString())
                  as List)
              .first
          as Map<String, dynamic>;
  final pipeline = HtmlSourcePipeline(source, HttpSourceTransport());
  final hits = await pipeline.search('凡人修仙传');
  final selected = hits.firstWhere((hit) => hit.title == '凡人修仙传');
  final (book, chapters) = await pipeline.details(selected);
  final checked = <Map<String, Object>>[];
  for (final chapter in chapters.take(2)) {
    final body = await pipeline.chapter(chapter);
    if (body.text.length < 300) throw StateError('Chapter too short');
    checked.add({
      'name': chapter.name,
      'url': '${chapter.url}',
      'pages': body.pages,
      'characters': body.text.length,
    });
  }
  final report = {
    'time': DateTime.now().toIso8601String(),
    'engine': 'Liber HtmlSourcePipeline / html 0.15.6',
    'title': book.title,
    'author': book.author,
    'tocPages': pipeline.tocPages,
    'chapters': chapters.length,
    'checkedChapters': checked,
    'requests': pipeline.trace
        .map((e) => {'stage': e.stage.name, 'url': e.path})
        .toList(),
    'verdict': 'pass',
  };
  await File(
    'book_sources/shudugu.liber-validation.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(
    'PASS: ${book.title}; ${chapters.length} chapters; ${pipeline.tocPages} TOC pages; ${checked.map((e) => e['pages']).toList()} content pages',
  );
}
