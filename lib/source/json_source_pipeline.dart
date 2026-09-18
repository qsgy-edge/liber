import 'dart:convert';

import '../domain/contracts.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'json_source_rules.dart';
import 'js_source_runtime.dart';
import 'source_host_dispatcher.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';
import 'source_url_rules.dart';

/// The bounded JSON-only Legado source slice, behind the shared pipeline shape.
///
/// A JSON Book Source runs the same four stages over the same HTTP semantics as
/// an HTML one; only the rule reader differs, so this adapter reaches the shelf
/// and the reader through [BookSourcePipeline] instead of stopping at the trial
/// page (ticket #29). The rule subset stays bounded — [JsonSourceRules]
/// documents what it reads, and every rule it cannot read is refused by name
/// before anything is sent.
class JsonSourcePipeline implements BookSourcePipeline {
  JsonSourcePipeline(
    this.source,
    this.transport, {
    this.headers = const {},
    this.hostState,
    this.androidId = '',
    this.onHostMessage,
  });

  @override
  final Map<String, dynamic> source;

  @override
  final BookSourceTransport transport;

  /// Extra headers the caller sends with every request, after the source's own.
  final Map<String, String> headers;

  @override
  void Function(SourceHostMessage message)? onHostMessage;

  /// The space's host surface, when the caller has one (ADR 0011 §3): cookies,
  /// cache entries and per-source variables outlive the analysis. Without one
  /// they live for the process.
  final SourceHostState? hostState;

  /// The installation's opaque `androidId` the source's `java.androidId` answers
  /// with (ADR 0011 §6); empty when the caller has no installation.
  final String androidId;

  /// The source this analysis speaks for: its `bookSourceUrl`, the key its TLS
  /// exception is looked up under and the owner of its host-surface state.
  ///
  /// Late, not eager: a source whose URL cannot be parsed must fail inside a
  /// stage, where the page that opened the analysis reports it, not while a
  /// page builds its pipeline.
  late final Uri _base = SourceHttpUri.parse(source['bookSourceUrl'] as String);
  late final String _sourceRef = '$_base';

  /// The frozen `AnalyzeUrl` page: a search carries one, every other stage is
  /// built without one, so `{{page}}` and `<a,b>` stay empty there.
  int? _page;

  /// The keyword the analysis was started with. A search carries it in its URL;
  /// a TOC or chapter URL a rule extracted can still interpolate it.
  String _keyword = '';

  /// The frozen `AnalyzeUrl` options one analysis owns: the options a stage's
  /// URL carried, kept for the stage that fetches it, because a book URL and a
  /// chapter URL are handed around without them.
  final _bookOptions = <Uri, SourceUrlOptions>{};
  final _chapterOptions = <Uri, SourceUrlOptions>{};

  final _cancellation = SourceCancellation();

  @override
  final trace = <BookSourceTraceEntry>[];

  late final SourceHostDispatcher? _host = transport is SourceHttpTransport
      ? SourceHostDispatcher(
          transport: transport as SourceHttpTransport,
          hostState: hostState,
          sourceRef: _sourceRef,
          concurrentRate: '${source['concurrentRate'] ?? ''}',
          // Frozen `AnalyzeUrl.enabledCookieJar`: only an explicit `true`
          // enables the response cookie jar; the null default is false.
          enabledCookieJar: source['enabledCookieJar'] == true,
        )
      : null;

  late final SourceScriptRuntime _runtime = InProcessSourceScriptRuntime(
    jsLib: source['jsLib'] as String? ?? '',
    dispatcher: _host,
    hostState: hostState,
    androidId: androidId,
    onMessage: (message) => onHostMessage?.call(message),
  );

  /// The headers every request and `java.ajax` carries: the source's own
  /// `header` rule, then the caller's. Read once per analysis and before the
  /// first request, because a `<js>` header rule can itself reach the network.
  Map<String, String> _activeHeaders = const {};
  Future<Map<String, String>>? _resolvedHeaders;

  @override
  void cancel() => _cancellation.cancel();

  /// Refuses what this adapter cannot run, before a request is sent.
  void _validate() {
    _cancellation.throwIfCancelled();
    if ((source['loginCheckJs']?.toString() ?? '').isNotEmpty) {
      throw UnsupportedError('Source field is not supported yet: loginCheckJs');
    }
    final rawHeader = source['header'];
    if (rawHeader != null && rawHeader is! String) {
      throw const FormatException('书源 header 必须是 JSON 字符串或 JS 规则');
    }
  }

  Future<Map<String, String>> _ensureHeaders() =>
      _resolvedHeaders ??= _readHeaders();

  /// The source fields a script can read, as the frozen `source` object exposes
  /// them.
  Map<String, Object?> get _sourceFields => {
    'bookSourceUrl': source['bookSourceUrl'],
    'bookSourceName': source['bookSourceName'],
    'bookSourceGroup': source['bookSourceGroup'],
    'bookSourceType': source['bookSourceType'],
    'bookSourceComment': source['bookSourceComment'],
    'enabledCookieJar': source['enabledCookieJar'],
    'loginUrl': source['loginUrl'],
  };

  Future<Object?> _evalJs(String script, String keyword, Object? result) =>
      _runtime.evaluate(
        source: script,
        input: {
          'sourceKey': _sourceRef,
          'source': _sourceFields,
          'key': keyword,
          'page': _page,
          'baseUrl': '$_base',
          'result': result,
          'headers': _activeHeaders,
        },
        timeout: const Duration(seconds: 30),
        cancellation: _cancellation,
      );

  Future<String> _expand(String template, String keyword) => expandSourceUrl(
    template,
    (expression, result) {
      // `{{key}}`/`{{page}}` are JavaScript bindings in the frozen runtime, so
      // a bare expression substitutes the raw value; the request's query or
      // body encoder escapes it later.
      final trimmed = expression.trim();
      if (trimmed == 'key') return Future<Object?>.value(keyword);
      if (trimmed == 'page') return Future<Object?>.value(_page);
      return _evalJs(expression, keyword, result);
    },
    page: _page,
  );

  /// Evaluates the source `header` rule: static JSON, `@js:` or `<js>`.
  Future<Map<String, String>> _readHeaders() async {
    final raw = source['header'];
    if (raw == null) return {...headers};
    final text = (raw as String).trim();
    if (text.isEmpty) return {...headers};
    final String json;
    if (text.toLowerCase().startsWith('@js:')) {
      json = '${await _evalJs(text.substring(4), _keyword, null)}';
    } else if (text.toLowerCase().startsWith('<js>')) {
      final end = text.lastIndexOf('<');
      if (end <= 4) {
        throw const FormatException('书源 header 的 <js> 规则缺少结束标记');
      }
      json = '${await _evalJs(text.substring(4, end), _keyword, null)}';
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
    return {...Map<String, String>.from(parsed), ...headers};
  }

  /// Expands one rule, splits its URL options, and applies the `js` option.
  Future<(Uri, SourceUrlOptions)> _request(
    Uri base,
    String template,
    String keyword,
  ) async {
    final split = splitSourceUrlOptions(await _expand(template, keyword));
    var url = _url(base, split.path);
    final script = split.options.js;
    final text = script == null
        ? split.path
        : '${await _evalJs(script, keyword, '$url')}';
    url = _url(base, text);
    if (!split.options.isPost) {
      url = _url(
        base,
        await encodeSourceQuery(
          sourceUrlTextWithRawQuery(url, text),
          charset: split.options.charset,
        ),
      );
    }
    return (url, split.options);
  }

  Future<Object?> _fetch(
    BookSourceStage stage,
    Uri url, {
    SourceUrlOptions options = const SourceUrlOptions(),
  }) async {
    _cancellation.throwIfCancelled();
    final merged = {..._activeHeaders, ...options.headers};
    final (method: method, body: body, headers: extra) = await sourceRequestShape(
      options,
      merged,
    );
    final headers = {...merged, ...extra};
    final host = _host;
    if (host != null) {
      // The same dispatcher every other source request goes through, so the
      // JSON stages carry cookies, the source's rate limit and the response
      // decoding exactly as the HTML stages do.
      final response = await host
          .forExecution(_cancellation)
          .request(
            method,
            '$url',
            headers: headers,
            body: body,
            retry: options.retry,
          );
      trace.add(BookSourceTraceEntry(stage: stage, path: url.toString()));
      _cancellation.throwIfCancelled();
      return jsonDecode(response.body);
    }
    if (method != 'GET' || headers.isNotEmpty) {
      throw UnsupportedError('当前 transport 不支持 HTTP 请求选项');
    }
    final text = await transport.request(stage: stage, path: url.toString());
    trace.add(BookSourceTraceEntry(stage: stage, path: url.toString()));
    _cancellation.throwIfCancelled();
    return jsonDecode(text);
  }

  /// The rule map of one stage, refusing an unsupported rule by name.
  Map<String, String> _rules(String key, List<String> required) {
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

  /// One optional extraction: the rule's value, or an empty string when the
  /// document does not carry it. A rule that cannot be read at all still
  /// throws, so a broken rule is reported instead of disappearing.
  static String _optional(Object? value, String rule) {
    if (rule.trim().isEmpty) return '';
    final normalized = rule.split(RegExp(r'\s+@js:')).first.trim();
    if (normalized.startsWith(r'$')) {
      return JsonSourceRules.read(value, normalized)?.toString() ?? '';
    }
    return JsonSourceRules.template(value, rule);
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

  /// `ruleSearch`: the books a keyword search returns.
  @override
  Future<List<HtmlBook>> search(String keyword, {int page = 1}) async {
    _validate();
    _keyword = keyword;
    _page = page;
    final search = _rules('ruleSearch', ['bookList', 'name', 'bookUrl']);
    _activeHeaders = await _ensureHeaders();
    final (url, options) = await _request(
      _base,
      source['searchUrl'] as String,
      keyword,
    );
    final document = await _fetch(
      BookSourceStage.search,
      url,
      options: options,
    );
    final found = JsonSourceRules.list(document, search['bookList']!);
    final books = <HtmlBook>[];
    for (final entry in found) {
      // A book URL is resolved against the search request's own URL, the way the
      // frozen `AnalyzeUrl` chains its stages, and keeps the options it carried
      // for the details fetch.
      final (bookUrl, bookOptions) = await _request(
        url,
        JsonSourceRules.template(entry, search['bookUrl']!),
        keyword,
      );
      _bookOptions[bookUrl] = bookOptions;
      books.add(
        HtmlBook(
          url: bookUrl,
          title: JsonSourceRules.text(entry, search['name']!),
          author: _optional(entry, search['author'] ?? ''),
          kind: _optional(entry, search['kind'] ?? ''),
        ),
      );
    }
    return books;
  }

  /// `ruleBookInfo` plus `ruleToc`: the book's own page and its chapter list.
  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async {
    _validate();
    _page = null;
    _activeHeaders = await _ensureHeaders();
    final info = _rules('ruleBookInfo', ['name', 'tocUrl']);
    final toc = _rules('ruleToc', ['chapterList', 'chapterName', 'chapterUrl']);
    final document = await _fetch(
      BookSourceStage.bookInfo,
      hit.url,
      options: _bookOptions.remove(hit.url) ?? const SourceUrlOptions(),
    );
    // The frozen `ruleBookInfo.init` moves the document the remaining rules
    // read into a subtree of the response.
    final page =
        source['ruleBookInfo'] is Map &&
            (source['ruleBookInfo'] as Map)['init'] is String
        ? JsonSourceRules.read(
            document,
            (source['ruleBookInfo'] as Map)['init'] as String,
          )
        : document;
    final cover = _optional(page, info['coverUrl'] ?? '');
    final book = HtmlBook(
      url: hit.url,
      title: JsonSourceRules.text(page, info['name']!),
      author: _optional(page, info['author'] ?? ''),
      intro: _optional(page, info['intro'] ?? ''),
      cover: cover.isEmpty ? '' : '${_url(hit.url, cover)}',
      kind: _optional(page, info['kind'] ?? ''),
      lastChapter: _optional(page, info['lastChapter'] ?? ''),
    );
    final (tocUrl, tocOptions) = await _request(
      hit.url,
      JsonSourceRules.template(page, info['tocUrl']!),
      _keyword,
    );
    final listing = await _fetch(
      BookSourceStage.tableOfContents,
      tocUrl,
      options: tocOptions,
    );
    final entries = JsonSourceRules.list(listing, toc['chapterList']!);
    final chapters = <SourceChapter>[];
    for (final entry in entries) {
      var chapterUrl = JsonSourceRules.text(entry, toc['chapterUrl']!);
      // The frozen 猫眼 rule decrypts its chapter path inside the rule itself,
      // which the bounded rule reader does not run.
      if (toc['chapterUrl']!.contains('@js:java.aesBase64DecodeToString')) {
        chapterUrl = aesBase64DecodeToString(
          chapterUrl,
          'f041c49714d39908',
          '0123456789abcdef',
        );
      }
      final (resolved, chapterOptions) = await _request(
        tocUrl,
        chapterUrl,
        _keyword,
      );
      _chapterOptions[resolved] = chapterOptions;
      chapters.add(
        SourceChapter(
          JsonSourceRules.text(entry, toc['chapterName']!),
          resolved,
        ),
      );
    }
    if (chapters.isEmpty) throw StateError('Empty table of contents');
    return (book, chapters);
  }

  /// `ruleContent`: one chapter's text.
  @override
  Future<HtmlChapterBody> chapter(SourceChapter chapter) async {
    _validate();
    _page = null;
    _activeHeaders = await _ensureHeaders();
    final content = _rules('ruleContent', ['content']);
    final document = await _fetch(
      BookSourceStage.content,
      chapter.url,
      options: _chapterOptions.remove(chapter.url) ?? const SourceUrlOptions(),
    );
    final text = JsonSourceRules.text(document, content['content']!);
    return HtmlChapterBody(text, 1);
  }

  /// One book, end to end, over the three stage entries.
  ///
  /// The runtime gates and the CLI tools read a source through this; the pages
  /// the product runs call the stages themselves. The stage stream is the one
  /// the unsplit `run` reported: search, book information, table of contents,
  /// content, completed.
  Future<SourceReadingResult> run(
    String keyword,
    void Function(BookSourceRunState) onStage, {
    int page = 1,
  }) async {
    var stage = BookSourceStage.search;
    try {
      // Every rule group is read before the first request, so a source with an
      // unsupported rule fails without touching the network.
      _rules('ruleSearch', ['bookList', 'name', 'bookUrl']);
      _rules('ruleBookInfo', ['name', 'tocUrl']);
      _rules('ruleToc', ['chapterList', 'chapterName', 'chapterUrl']);
      _rules('ruleContent', ['content']);
      onStage(
        const BookSourceRunState(
          stage: BookSourceStage.search,
          message: '正在搜索',
        ),
      );
      final books = await search(keyword, page: page);
      if (books.isEmpty) throw StateError('No search results');
      stage = BookSourceStage.bookInfo;
      onStage(
        BookSourceRunState(stage: stage, message: '读取 ${books.first.title}'),
      );
      final (book, chapters) = await details(books.first);
      stage = BookSourceStage.tableOfContents;
      onStage(
        const BookSourceRunState(
          stage: BookSourceStage.tableOfContents,
          message: '读取目录',
        ),
      );
      stage = BookSourceStage.content;
      onStage(
        BookSourceRunState(stage: stage, message: '读取 ${chapters.first.name}'),
      );
      final body = await chapter(chapters.first);
      onStage(
        const BookSourceRunState(
          stage: BookSourceStage.completed,
          message: '首章读取完成（JSON 规则子集）',
        ),
      );
      return SourceReadingResult(book.title, chapters, body.text, trace);
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
