// Manual review entry point; renders the actual product browser and reader.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:liber/source/html_source_browser.dart';

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
  runApp(
    MaterialApp(
      title: 'Liber · ${source['bookSourceName']}',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff315c72)),
        useMaterial3: true,
      ),
      home: HtmlSourceBrowser(source: source, keyword: keyword),
    ),
  );
}
