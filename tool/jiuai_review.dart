// Manual review entry point; renders the actual product browser and reader.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const path = String.fromEnvironment('LIBER_REVIEW_SOURCE');
  const keyword = String.fromEnvironment(
    'LIBER_REVIEW_KEYWORD',
    defaultValue: '回放',
  );
  if (path.isEmpty) {
    throw StateError('Set LIBER_REVIEW_SOURCE to a Book Source JSON path');
  }
  final source =
      jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
  // A review reads and writes a space of its own: it must not touch the
  // operator's library.
  final directory = await Directory.systemTemp.createTemp('liber-review-');
  final service = ShelfService(
    SpaceStore(SpaceDatabase.file(File('${directory.path}/data.db'))),
  );
  runApp(
    MaterialApp(
      title: 'Liber · ${source['bookSourceName']}',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff315c72)),
        useMaterial3: true,
      ),
      home: HtmlSourceBrowser(
        source: source,
        keyword: keyword,
        service: service,
      ),
    ),
  );
}
