import 'dart:convert';

import '../domain/contracts.dart';
import 'book_source_service.dart';
import 'json_source_rules.dart';
import 'js_source_runtime.dart';
import 'source_host_dispatcher.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';
import 'source_url_rules.dart';

/// A bounded JSON-only Legado source slice, not a complete rule runtime.
class JsonSourcePipeline {
  JsonSourcePipeline(
    this.transport, {
    this.headers = const {},
    this.hostState,
  });
  final BookSourceTransport transport;
  Map<String, String> _activeHeaders = const {};
  final Map<String, String> headers;

  /// The space's host surface, when the caller has one (ADR 0011 §3): cookies,
  /// cache entries and per-source variables outlive the run. Without one they
  /// live for the process.
  final SourceHostState? hostState;

  Future<SourceReadingResult> run(
    Map<String, dynamic> source,
    String keyword,
    void Function(BookSourceRunState) onStage, {
    int page = 1,
  }) async {
    final trace = <BookSourceTraceEntry>[];
    var stage = BookSourceStage.search;
    // The frozen search URL carries an `AnalyzeUrl` page; every later stage is
    // built without one, so `{{page}}` and `<a,b>` stay empty there.
    int? activePage = page;
    try {
      final search = _rules(source, 'ruleSearch', [
        'bookList',
        'name',
        'bookUrl',
      ]);
      final info = _rules(source, 'ruleBookInfo', ['name', 'tocUrl']);
      final toc = _rules(source, 'ruleToc', [
        'chapterList',
        'chapterName',
        'chapterUrl',
      ]);
      final content = _rules(source, 'ruleContent', ['content']);
      for (final field in ['loginCheckJs']) {
        if ((source[field]?.toString() ?? '').isNotEmpty) {
          throw UnsupportedError('Source field is not supported yet: $field');
        }
      }
      final rawHeader = source['header'];
      if (rawHeader != null && rawHeader is! String) {
        throw const FormatException('书源 header 必须是 JSON 字符串或 JS 规则');
      }
      final base = SourceHttpUri.parse(source['bookSourceUrl'] as String);
      final runtime = InProcessSourceScriptRuntime(
        jsLib: source['jsLib'] as String? ?? '',
        dispatcher: transport is SourceHttpTransport
            ? SourceHostDispatcher(
                transport: transport as SourceHttpTransport,
                hostState: hostState,
                sourceRef: '$base',
              )
            : null,
        hostState: hostState,
      );
      Map<String, Object?> scriptInput(Object? result) => {
        'sourceKey': '$base',
        'source': {
          'bookSourceUrl': source['bookSourceUrl'],
          'bookSourceName': source['bookSourceName'],
          'bookSourceGroup': source['bookSourceGroup'],
          'bookSourceType': source['bookSourceType'],
          'bookSourceComment': source['bookSourceComment'],
          'enabledCookieJar': source['enabledCookieJar'],
          'loginUrl': source['loginUrl'],
        },
        'key': keyword,
        'page': activePage,
        'baseUrl': '$base',
        'result': result,
        'headers': _activeHeaders,
      };
      Future<Object?> evaluate(String script, Object? result) =>
          runtime.evaluate(
            source: script,
            input: scriptInput(result),
            timeout: const Duration(seconds: 30),
          );
      Future<String> expand(String value) => expandSourceUrl(
        value,
        (script, result) {
          // `{{key}}`/`{{page}}` are JavaScript bindings in the frozen runtime,
          // so a bare expression substitutes the raw value; the request's
          // query or body encoder escapes it later.
          final trimmed = script.trim();
          if (trimmed == 'key') return Future<Object?>.value(keyword);
          if (trimmed == 'page') return Future<Object?>.value(activePage);
          return evaluate(script, result);
        },
        page: activePage,
      );
      // Frozen `BaseSource.getHeaderMap`: static JSON, `@js:` or `<js>`.
      Future<Map<String, String>> sourceHeaders() async {
        if (rawHeader == null) return const {};
        final text = (rawHeader as String).trim();
        if (text.isEmpty) return const {};
        final String json;
        if (text.toLowerCase().startsWith('@js:')) {
          json = '${await evaluate(text.substring(4), null)}';
        } else if (text.toLowerCase().startsWith('<js>')) {
          final end = text.lastIndexOf('<');
          if (end <= 4) {
            throw const FormatException('书源 header 的 <js> 规则缺少结束标记');
          }
          json = '${await evaluate(text.substring(4, end), null)}';
        } else {
          json = text;
        }
        final parsed = jsonDecode(json);
        if (parsed is! Map ||
            parsed.entries.any((e) => e.key is! String || e.value is! String)) {
          throw const FormatException('书源 header 规则必须返回 JSON 字符串映射');
        }
        if (parsed.keys.any((key) => '$key'.toLowerCase() == 'proxy')) {
          throw UnsupportedError('暂不支持代理配置');
        }
        return Map<String, String>.from(parsed);
      }

      _activeHeaders = {...await sourceHeaders(), ...headers};
      // Expands one rule, splits its URL options, and applies the `js` option.
      var pending = const SourceUrlOptions();
      Future<Uri> rule(Uri root, String expanded) async {
        final split = splitSourceUrlOptions(expanded);
        var url = _url(root, split.path);
        final script = split.options.js;
        if (script != null) {
          url = _url(root, '${await evaluate(script, '$url')}');
        }
        if (!split.options.isPost) {
          url = _url(root, encodeSourceQuery('$url'));
        }
        pending = split.options;
        return url;
      }

      var url = await rule(base, await expand(source['searchUrl'] as String));
      var options = pending;
      onStage(BookSourceRunState(stage: stage, message: '正在搜索'));
      var document = await _fetch(stage, url, trace, options: options);
      final books = JsonSourceRules.list(document, search['bookList']!);
      if (books.isEmpty) throw StateError('No search results');
      final selected = books.first;
      final searchTitle = JsonSourceRules.text(selected, search['name']!);
      url = await rule(
        url,
        await expand(JsonSourceRules.template(selected, search['bookUrl']!)),
      );
      options = pending;

      stage = BookSourceStage.bookInfo;
      activePage = null;
      onStage(BookSourceRunState(stage: stage, message: '读取 $searchTitle'));
      document = await _fetch(stage, url, trace, options: options);
      if (source['ruleBookInfo'] is Map &&
          (source['ruleBookInfo'] as Map)['init'] is String) {
        document = JsonSourceRules.read(
          document,
          (source['ruleBookInfo'] as Map)['init'] as String,
        );
      }
      final title = JsonSourceRules.text(document, info['name']!);
      url = await rule(
        url,
        await expand(JsonSourceRules.template(document, info['tocUrl']!)),
      );
      options = pending;

      stage = BookSourceStage.tableOfContents;
      onStage(BookSourceRunState(stage: stage, message: '读取目录'));
      document = await _fetch(stage, url, trace, options: options);
      final rawChapters = JsonSourceRules.list(document, toc['chapterList']!);
      final chapters = <SourceChapter>[];
      var contentOptions = const SourceUrlOptions();
      for (final entry in rawChapters) {
        var chapterUrl = JsonSourceRules.text(entry, toc['chapterUrl']!);
        if (toc['chapterUrl']!.contains('@js:java.aesBase64DecodeToString')) {
          chapterUrl = aesBase64DecodeToString(
            chapterUrl,
            'f041c49714d39908',
            '0123456789abcdef',
          );
        }
        final resolved = await rule(url, await expand(chapterUrl));
        if (chapters.isEmpty) contentOptions = pending;
        chapters.add(
          SourceChapter(
            JsonSourceRules.text(entry, toc['chapterName']!),
            resolved,
          ),
        );
      }
      if (chapters.isEmpty) throw StateError('Empty table of contents');

      stage = BookSourceStage.content;
      onStage(
        BookSourceRunState(stage: stage, message: '读取 ${chapters.first.name}'),
      );
      document = await _fetch(
        stage,
        chapters.first.url,
        trace,
        options: contentOptions,
      );
      final text = JsonSourceRules.text(document, content['content']!);
      onStage(
        const BookSourceRunState(
          stage: BookSourceStage.completed,
          message: '首章读取完成（JSON 规则子集）',
        ),
      );
      return SourceReadingResult(title, chapters, text, trace);
    } catch (error) {
      onStage(
        BookSourceRunState(
          stage: BookSourceStage.failed,
          message: '${stage.name}: $error',
        ),
      );
      rethrow;
    }
  }

  Future<Object?> _fetch(
    BookSourceStage stage,
    Uri url,
    List<BookSourceTraceEntry> trace, {
    SourceUrlOptions options = const SourceUrlOptions(),
  }) async {
    final merged = {..._activeHeaders, ...options.headers};
    final (method: method, body: body, headers: extra) = sourceRequestShape(
      options,
      merged,
    );
    final headers = {...merged, ...extra};
    if (transport is SourceHttpTransport) {
      final response = await (transport as SourceHttpTransport).send(
        SourceHttpRequest(
          method: method,
          url: url,
          headers: headers,
          body: body,
          retry: options.retry,
        ),
      );
      trace.add(BookSourceTraceEntry(stage: stage, path: url.toString()));
      return jsonDecode(response.body);
    }
    if (method != 'GET' || headers.isNotEmpty) {
      throw UnsupportedError('当前 transport 不支持 HTTP 请求选项');
    }
    final text = await transport.request(stage: stage, path: url.toString());
    trace.add(BookSourceTraceEntry(stage: stage, path: url.toString()));
    return jsonDecode(text);
  }

  static Map<String, String> _rules(
    Map<String, dynamic> source,
    String key,
    List<String> required,
  ) {
    final raw = source[key];
    if (raw is! Map) throw FormatException('Missing $key');
    final rules = <String, String>{};
    for (final entry in raw.entries) {
      if (entry.value == null || entry.value == '') continue;
      if (entry.value is! String && entry.key != 'canReName') {
        throw FormatException('Invalid $key.${entry.key}');
      }
      if (entry.value is! String) continue;
      if (required.contains(entry.key) && entry.key != 'checkKeyWord') {
        JsonSourceRules.validate(entry.value as String);
      }
      if (!required.contains(entry.key) &&
          !{
            'author',
            'coverUrl',
            'intro',
            'kind',
            'wordCount',
            'lastChapter',
            'updateTime',
            'canReName',
            'downloadUrls',
            'init',
            'checkKeyWord',
          }.contains(entry.key)) {
        throw UnsupportedError('Unsupported field: $key.${entry.key}');
      }
      rules[entry.key as String] = entry.value as String;
    }
    for (final name in required) {
      if (!rules.containsKey(name)) throw FormatException('Missing $key.$name');
    }
    return rules;
  }

  static Uri _url(Uri base, String path) {
    if (path.contains('{{') || path.startsWith('@js:')) {
      throw UnsupportedError('Unsupported URL rule');
    }
    final url = base.resolve(path);
    if (!['http', 'https'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      throw FormatException('Invalid source URL');
    }
    return url;
  }
}

class SourceChapter {
  const SourceChapter(this.name, this.url);
  final String name;
  final Uri url;
}

class SourceReadingResult {
  const SourceReadingResult(
    this.title,
    this.chapters,
    this.content,
    this.trace,
  );
  final String title;
  final List<SourceChapter> chapters;
  final String content;
  final List<BookSourceTraceEntry> trace;
}
