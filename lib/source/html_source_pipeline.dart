import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../domain/contracts.dart';
import 'book_source_service.dart';
import 'html_source_rules.dart';
import 'js_source_runtime.dart';
import 'source_host_dispatcher.dart';
import 'source_http_uri.dart';
import 'source_url_rules.dart';
import 'json_source_pipeline.dart' show SourceChapter;

class HtmlBook {
  const HtmlBook({
    required this.url,
    required this.title,
    this.author = '',
    this.intro = '',
    this.cover = '',
    this.kind = '',
    this.lastChapter = '',
  });
  final Uri url;
  final String title, author, intro, cover, kind, lastChapter;
  Map<String, dynamic> toJson() => {
    'url': '$url',
    'title': title,
    'author': author,
    'intro': intro,
    'cover': cover,
    if (kind.isNotEmpty) 'kind': kind,
    if (lastChapter.isNotEmpty) 'lastChapter': lastChapter,
  };
  factory HtmlBook.fromJson(Map<String, dynamic> value) => HtmlBook(
    url: SourceHttpUri.parse(value['url'] as String),
    title: value['title'] as String,
    author: value['author'] as String? ?? '',
    intro: value['intro'] as String? ?? '',
    cover: value['cover'] as String? ?? '',
    kind: value['kind'] as String? ?? '',
    lastChapter: value['lastChapter'] as String? ?? '',
  );
}

class HtmlChapterBody {
  const HtmlChapterBody(this.text, this.pages);
  final String text;
  final int pages;
}

class HtmlSourcePipeline {
  HtmlSourcePipeline(this.source, this.transport, {this._scriptRuntime});
  final Map<String, dynamic> source;
  final BookSourceTransport transport;
  final SourceScriptRuntime? _scriptRuntime;
  final _cancellation = SourceCancellation();
  late final SourceHostDispatcher? _host = transport is SourceHttpTransport
      ? SourceHostDispatcher(transport: transport as SourceHttpTransport)
      : null;
  late final SourceScriptRuntime _runtime =
      _scriptRuntime ??
      InProcessSourceScriptRuntime(
        dispatcher: _host,
        jsLib: source['jsLib'] as String? ?? '',
      );
  final trace = <BookSourceTraceEntry>[];
  int tocPages = 0;

  /// The frozen `AnalyzeUrl` page: a search carries one, every other stage is
  /// built without a page, so `{{page}}` and `<a,b>` stay empty there.
  int? _page;
  final _bookOptions = <Uri, SourceUrlOptions>{};
  bool get cancelled => _cancellation.isCancelled;
  void cancel() => _cancellation.cancel();

  /// Evaluates the source `header` rule: static JSON, `@js:` or `<js>`.
  ///
  /// The frozen `BaseSource.getHeaderMap` parses the rule as JSON after an
  /// `@js:`/`<js>` script produces it, and does not expand `{{ }}` here.
  Future<Map<String, String>> _headers() async {
    final raw = source['header'];
    if (raw == null || raw == '') return const {};
    if (raw is! String) {
      throw const FormatException('书源 header 必须是 JSON 字符串或 JS 规则');
    }
    final text = raw.trim();
    if (text.isEmpty) return const {};
    final String json;
    if (text.toLowerCase().startsWith('@js:')) {
      json = '${await _evalJs(text.substring(4), '', null)}';
    } else if (text.toLowerCase().startsWith('<js>')) {
      final end = text.lastIndexOf('<');
      if (end <= 4) throw const FormatException('书源 header 的 <js> 规则缺少结束标记');
      json = '${await _evalJs(text.substring(4, end), '', null)}';
    } else {
      json = text;
    }
    final Object? parsed;
    try {
      parsed = jsonDecode(json);
    } on FormatException catch (error) {
      throw FormatException('书源 header 规则必须返回 JSON：${error.message}');
    }
    if (parsed is! Map ||
        parsed.entries.any((e) => e.key is! String || e.value is! String)) {
      throw const FormatException('书源 header 规则必须返回 JSON 字符串映射');
    }
    if (parsed.keys.any((key) => '$key'.toLowerCase() == 'proxy')) {
      throw UnsupportedError('暂不支持代理配置');
    }
    return Map<String, String>.from(parsed);
  }

  void _validate() {
    _cancellation.throwIfCancelled();
    for (final key in ['loginUrl', 'loginCheckJs']) {
      if ((source[key]?.toString() ?? '').isNotEmpty) {
        throw UnsupportedError('暂不支持 $key');
      }
    }
  }

  Future<Object?> _evalJs(String script, String keyword, Object? result) =>
      _runtime.evaluate(
        source: script,
        input: {
          'sourceKey': source['bookSourceUrl'],
          'key': keyword,
          'page': _page,
          'result': result,
          'baseUrl': source['bookSourceUrl'],
          'headers': const <String, String>{},
        },
        timeout: const Duration(seconds: 30),
        cancellation: _cancellation,
      );

  Future<String> _expand(String template, String keyword) async {
    return expandSourceUrl(
      template,
      (expression, result) {
        // The frozen runtime evaluates `{{key}}` and `{{page}}` as JavaScript
        // bindings; a bare `key` or `page` therefore substitutes the raw value
        // and the request's query/body encoder does any escaping later.
        final trimmed = expression.trim();
        if (trimmed == 'key') return Future<Object?>.value(keyword);
        if (trimmed == 'page') return Future<Object?>.value(_page);
        return _evalJs(expression, keyword, result);
      },
      page: _page,
    );
  }

  /// Expands one rule, splits its URL options, and applies the `js` option.
  Future<(Uri, SourceUrlOptions)> _request(
    Uri base,
    String template,
    String keyword,
  ) async {
    final split = splitSourceUrlOptions(await _expand(template, keyword));
    var url = _resolve(base, split.path, keepFragment: true);
    final script = split.options.js;
    if (script != null) {
      final value = await _evalJs(script, keyword, '$url');
      url = _resolve(base, '$value', keepFragment: true);
    }
    if (!split.options.isPost) {
      url = _resolve(base, encodeSourceQuery('$url'));
    }
    return (url, split.options);
  }

  /// Resolves an already-extracted rule value that may carry URL options.
  (Uri, SourceUrlOptions) _extracted(Uri base, String value) {
    final split = splitSourceUrlOptions(value);
    var url = _resolve(base, split.path, keepFragment: true);
    if (!split.options.isPost) {
      url = _resolve(base, encodeSourceQuery('$url'));
    }
    return (url, split.options);
  }

  String _rule(String group, String key, {bool optional = false}) {
    final rules = source[group];
    final rule = rules is Map ? rules[key] : null;
    if (rule is String && rule.isNotEmpty) return rule;
    if (optional) return '';
    throw FormatException('缺少 $group.$key');
  }

  String _value(
    Node context,
    String group,
    String key, {
    bool optional = false,
  }) {
    final rule = _rule(group, key, optional: optional);
    if (rule.isEmpty) return '';
    final value = HtmlSourceRules.text(context, rule);
    if (!optional && value.isEmpty) throw FormatException('$group.$key 未匹配到内容');
    return value;
  }

  /// Resolves a rule value against [base]. A URL that is about to be fetched
  /// keeps its fragment, because the frozen `analyzeQuery` folds everything
  /// after the first `?` (a `#` included) into the query before the request is
  /// built; every other use drops it as before.
  Uri _resolve(Uri base, String path, {bool keepFragment = false}) {
    final resolved = base.resolve(path);
    final uri = keepFragment ? resolved : resolved.removeFragment();
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw FormatException('非法书源地址：$uri');
    }
    return uri;
  }

  Future<(Document, Uri)> _fetch(
    Uri url,
    BookSourceStage stage, {
    SourceUrlOptions options = const SourceUrlOptions(),
  }) async {
    _validate();
    final sourceHeaders = await _headers();
    final merged = {...sourceHeaders, ...options.headers};
    final (method: method, body: body, headers: extra) = sourceRequestShape(
      options,
      merged,
    );
    final headers = {...merged, ...extra};
    final host = _host;
    String text;
    var finalUrl = url;
    if (host != null) {
      final response = await host
          .forExecution(_cancellation)
          .request(
            method,
            '$url',
            headers: headers,
            body: body,
            retry: options.retry,
          );
      text = response.body;
      finalUrl = response.url;
    } else {
      if (method != 'GET' || headers.isNotEmpty) {
        throw UnsupportedError('当前 transport 不支持 HTTP 请求选项');
      }
      text = await transport.request(stage: stage, path: '$url');
    }
    _cancellation.throwIfCancelled();
    trace.add(BookSourceTraceEntry(stage: stage, path: '$url'));
    return (html.parse(text), finalUrl);
  }

  Future<List<HtmlBook>> search(String keyword, {int page = 1}) async {
    _validate();
    _page = page;
    final base = SourceHttpUri.parse(source['bookSourceUrl'] as String);
    final (url, options) = await _request(
      base,
      source['searchUrl'] as String,
      keyword,
    );
    final (doc, finalUrl) = await _fetch(
      url,
      BookSourceStage.search,
      options: options,
    );
    return HtmlSourceRules.elements(doc, _rule('ruleSearch', 'bookList')).map((
      item,
    ) {
      final (bookUrl, bookOptions) = _extracted(
        finalUrl,
        _value(item, 'ruleSearch', 'bookUrl'),
      );
      _bookOptions[bookUrl] = bookOptions;
      return HtmlBook(
        url: bookUrl,
        title: _value(item, 'ruleSearch', 'name'),
        author: _value(item, 'ruleSearch', 'author', optional: true),
        kind: _value(item, 'ruleSearch', 'kind', optional: true),
      );
    }).toList();
  }

  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async {
    _page = null;
    final (doc, infoUrl) = await _fetch(
      hit.url,
      BookSourceStage.bookInfo,
      options: _bookOptions.remove(hit.url) ?? const SourceUrlOptions(),
    );
    final cover = _value(doc, 'ruleBookInfo', 'coverUrl', optional: true);
    final book = HtmlBook(
      url: hit.url,
      title: _value(doc, 'ruleBookInfo', 'name'),
      author: _value(doc, 'ruleBookInfo', 'author', optional: true),
      intro: _value(doc, 'ruleBookInfo', 'intro', optional: true),
      cover: cover.isEmpty ? '' : '${_resolve(infoUrl, cover)}',
      kind: _value(doc, 'ruleBookInfo', 'kind', optional: true),
      lastChapter: _value(doc, 'ruleBookInfo', 'lastChapter', optional: true),
    );
    var url = _resolve(infoUrl, _value(doc, 'ruleBookInfo', 'tocUrl'));
    var tocOptions = _extracted(infoUrl, _value(doc, 'ruleBookInfo', 'tocUrl'));
    url = tocOptions.$1;
    var options = tocOptions.$2;
    final visited = <Uri>{};
    final chapterUrls = <Uri>{};
    final chapters = <SourceChapter>[];
    tocPages = 0;
    while (true) {
      if (!visited.add(url) || visited.length > 30) {
        throw StateError('目录分页循环或超出 30 页');
      }
      final (page, pageUrl) = await _fetch(
        url,
        BookSourceStage.tableOfContents,
        options: options,
      );
      tocPages++;
      final items = HtmlSourceRules.elements(
        page,
        _rule('ruleToc', 'chapterList'),
      );
      if (items.isEmpty) throw StateError('目录页为空');
      for (final item in items) {
        final (chapterUrl, chapterOptions) = _extracted(
          pageUrl,
          _value(item, 'ruleToc', 'chapterUrl'),
        );
        if (chapterOptions.isPost ||
            chapterOptions.body != null ||
            chapterOptions.headers.isNotEmpty ||
            chapterOptions.retry != 0 ||
            chapterOptions.js != null) {
          throw UnsupportedError('暂不支持章节地址的 URL 选项');
        }
        if (!chapterUrls.add(chapterUrl)) {
          throw StateError('目录含重复章节：$chapterUrl');
        }
        chapters.add(
          SourceChapter(_value(item, 'ruleToc', 'chapterName'), chapterUrl),
        );
      }
      final next = _value(page, 'ruleToc', 'nextTocUrl', optional: true);
      if (next.isEmpty) break;
      final (nextUrl, nextOptions) = _extracted(pageUrl, next);
      url = nextUrl;
      options = nextOptions;
    }
    return (book, chapters);
  }

  Future<HtmlChapterBody> chapter(SourceChapter chapter) async {
    _page = null;
    var url = chapter.url;
    final visited = <Uri>{};
    final parts = <String>[];
    var retry = 0;
    while (true) {
      if (!visited.add(url) || visited.length > 20) {
        throw StateError('正文分页循环或超出 20 页');
      }
      final (doc, pageUrl) = await _fetch(
        url,
        BookSourceStage.content,
        options: SourceUrlOptions(retry: retry),
      );
      var text = _value(doc, 'ruleContent', 'content');
      final replacement = _rule(
        'ruleContent',
        'replaceRegex',
        optional: true,
      ).replaceAll('{{chapter.title}}', chapter.name);
      if (replacement.contains('{{')) throw UnsupportedError('暂不支持该正文替换表达式');
      if (replacement.isNotEmpty) {
        text = HtmlSourceRules.replace(text, replacement);
      }
      parts.add(text);
      final next = _value(doc, 'ruleContent', 'nextContentUrl', optional: true);
      if (next.isEmpty) break;
      final (nextUrl, nextOptions) = _extracted(pageUrl, next);
      if (nextOptions.isPost ||
          nextOptions.body != null ||
          nextOptions.headers.isNotEmpty ||
          nextOptions.js != null) {
        throw UnsupportedError('暂不支持正文分页地址的 URL 选项');
      }
      retry = nextOptions.retry;
      url = nextUrl;
    }
    return HtmlChapterBody(parts.join('\n'), visited.length);
  }
}
