import 'dart:convert';

import '../domain/contracts.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'html_rule_adapter.dart';
import 'js_source_runtime.dart';
import 'rule_field.dart';
import 'source_host_dispatcher.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';
import 'source_url_rules.dart';

class HtmlBook {
  const HtmlBook({
    required this.url,
    required this.title,
    this.author = '',
    this.intro = '',
    this.cover = '',
    this.kind = '',
    this.lastChapter = '',
    this.wordCount = '',
  });
  final Uri url;
  final String title, author, intro, cover, kind, lastChapter, wordCount;
  Map<String, dynamic> toJson() => {
    'url': '$url',
    'title': title,
    'author': author,
    'intro': intro,
    'cover': cover,
    if (kind.isNotEmpty) 'kind': kind,
    if (lastChapter.isNotEmpty) 'lastChapter': lastChapter,
    if (wordCount.isNotEmpty) 'wordCount': wordCount,
  };
  factory HtmlBook.fromJson(Map<String, dynamic> value) => HtmlBook(
    url: SourceHttpUri.parse(value['url'] as String),
    title: value['title'] as String,
    author: value['author'] as String? ?? '',
    intro: value['intro'] as String? ?? '',
    cover: value['cover'] as String? ?? '',
    kind: value['kind'] as String? ?? '',
    lastChapter: value['lastChapter'] as String? ?? '',
    wordCount: value['wordCount'] as String? ?? '',
  );
}

class HtmlChapterBody {
  const HtmlChapterBody(this.text, this.pages, {this.title});
  final String text;
  final int pages;

  /// The content-stage `ruleContent.title`, or null when the source did not
  /// declare a title rule or it returned an empty value.
  final String? title;
}

/// The frozen four-stage HTML pipeline over the Rust rule adapter.
///
/// Every stage parses its page once and hands the whole document plus that
/// stage's rules to [HtmlRuleBatch], which is the frozen `AnalyzeByJSoup`
/// shape: one tree, many rules, one bridge call.
///
/// This is the [BookSourcePipeline] an HTML source gets; the pages hold the
/// interface, not this class (ticket #29).
class HtmlSourcePipeline implements BookSourcePipeline {
  HtmlSourcePipeline(
    this.source,
    this.transport, {
    this._scriptRuntime,
    this.hostState,
    this.androidId = '',
    this.onHostMessage,
  });
  @override
  final Map<String, dynamic> source;
  @override
  final BookSourceTransport transport;
  final SourceScriptRuntime? _scriptRuntime;

  /// The installation's opaque `androidId` the source's `java.androidId` answers
  /// with (ADR 0011 §6); empty when the caller has no installation, which is
  /// what the gates and the tools run with.
  final String androidId;

  /// Where a source's rate-limited `toast`/`longToast` notices go. Mutable so a
  /// page a pipeline is handed to — the reader takes the browser's pipeline over
  /// for its chapter fetch — can point it at its own messenger.
  @override
  void Function(SourceHostMessage message)? onHostMessage;

  /// The space's host surface, when the caller has one: the jar, the cache
  /// entries and the per-source variables a source writes outlive this pipeline
  /// (ADR 0011 §3, ticket #21). Without one they live for the process, which is
  /// what the gates and the tools need.
  final SourceHostState? hostState;

  /// The source this pipeline speaks for: its `bookSourceUrl`, the key its
  /// per-source state is owned by.
  String get _sourceRef => '${source['bookSourceUrl'] ?? ''}';

  final _cancellation = SourceCancellation();

  /// The rule variables (`@get:`/`@put:`) and the script runtime read one store,
  /// the way the frozen `AnalyzeRule.get`/`put` reach the same `BaseSource`
  /// variables `java.get`/`java.put` do.
  late final SourceHostState _hostSurface = hostState ?? SourceHostState();
  late final SourceHostDispatcher? _host = transport is SourceHttpTransport
      ? SourceHostDispatcher(
          transport: transport as SourceHttpTransport,
          hostState: _hostSurface,
          sourceRef: _sourceRef,
          concurrentRate: '${source['concurrentRate'] ?? ''}',
          // Frozen `AnalyzeUrl.enabledCookieJar`: only an explicit `true`
          // enables the response cookie jar; the null default is false.
          enabledCookieJar: source['enabledCookieJar'] == true,
        )
      : null;
  late final SourceScriptRuntime _runtime =
      _scriptRuntime ??
      InProcessSourceScriptRuntime(
        dispatcher: _host,
        hostState: _hostSurface,
        jsLib: source['jsLib'] as String? ?? '',
        androidId: androidId,
        onMessage: (message) => onHostMessage?.call(message),
      );
  @override
  final trace = <BookSourceTraceEntry>[];
  int tocPages = 0;

  /// The frozen `AnalyzeUrl` page: a search carries one, every other stage is
  /// built without a page, so `{{page}}` and `<a,b>` stay empty there.
  int? _page;

  /// The keyword the analysis was started with; a rule field's `{{...}}`
  /// expressions see it as the frozen `key` binding.
  String _keyword = '';

  /// The chapter whose title the frozen `AnalyzeRule` binds as `title` while the
  /// content stage runs; null in every other stage, exactly as `chapter?.title`
  /// is there. Book/chapter snapshots carry only existing stage result fields.
  String? _chapterTitle;
  HtmlBook? _book;
  SourceChapter? _chapter;
  final _bookOptions = <Uri, SourceUrlOptions>{};
  bool get cancelled => _cancellation.isCancelled;
  @override
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
          'sourceKey': _sourceRef,
          'source': _sourceFields,
          'key': keyword,
          'page': _page,
          'result': result,
          'baseUrl': source['bookSourceUrl'],
          'title': _chapterTitle,
          'book': _book == null
              ? null
              : {
                  'name': _book!.title,
                  'bookUrl': '${_book!.url}',
                  'author': _book!.author,
                  'intro': _book!.intro,
                  'coverUrl': _book!.cover,
                  'kind': _book!.kind,
                  'latestChapterTitle': _book!.lastChapter,
                  'wordCount': _book!.wordCount,
                },
          'chapter': _chapter == null
              ? null
              : {'title': _chapter!.name, 'url': '${_chapter!.url}'},
          'headers': const <String, String>{},
        },
        timeout: const Duration(seconds: 30),
        cancellation: _cancellation,
      );

  /// The shared rule-field path's edges for this adapter: the scripts go through
  /// the runtime the adapter already owns, a value rule is extracted by a
  /// one-rule Rust call ([_eagerExtract]), and `@get:`/`@put:` read and write the
  /// source-scoped variables `java.get`/`java.put` use.
  RuleFieldContext get _ruleContext => RuleFieldContext(
    evaluateScript: (script, result) => _evalJs(script, _keyword, result),
    extract: _eagerExtract,
    readVariable: _readRuleVariable,
    writeVariable: _writeRuleVariable,
  );

  Future<String> _readRuleVariable(String key) async {
    if (key == 'bookName') return _book?.title ?? '';
    if (key == 'title') return _chapterTitle ?? '';
    final value = await _hostSurface.entry(
      _sourceRef,
      sourceRuleVariableKey(_sourceRef, key),
    );
    return value is String ? value : '';
  }

  Future<void> _writeRuleVariable(String key, String value) => _hostSurface
      .putEntry(_sourceRef, sourceRuleVariableKey(_sourceRef, key), value);

  /// One rule field through the shared path: the `@js:`/`<js>` split and the
  /// `{{...}}`/`@get:`/`@put:` substitution happen before the stage's batch is
  /// declared, the script segments run on the extracted value afterwards.
  ///
  /// [allowScripts] is false for an element-*list* rule (`bookList`,
  /// `chapterList`): an element set is not a value this path can hand back, so a
  /// script there is refused by name rather than dropped.
  Future<RuleField> _field(
    String raw, {
    required String content,
    bool allowScripts = true,
  }) async {
    final field = await RuleField.resolve(raw, _ruleContext, content: content);
    if (!allowScripts && field.scripts.isNotEmpty) {
      throw UnsupportedError('暂不支持元素列表规则里的 JavaScript：$raw');
    }
    return field;
  }

  /// One per-element value rule of a stage. `{{...}}`/`@get:` substitution
  /// applies; a rule that is *only* a script is refused by name, because the
  /// frozen `result` of such a rule is the matched element, which the JavaScript
  /// boundary cannot carry.
  Future<RuleField> _elementField(String raw, {required String content}) async {
    final field = await _field(raw, content: content);
    if (field.isScriptOnly) {
      throw UnsupportedError('暂不支持只有脚本的元素规则：$raw');
    }
    return field;
  }

  /// Declares the document job of one field, or none when the field is a script
  /// only.
  HtmlString? _declare(HtmlRuleBatch batch, String id, RuleField field) =>
      field.isScriptOnly ? null : batch.documentText(id, field.extractionRule!);

  /// Reads one declared document job with the field's scripts applied. A
  /// script-only field is applied to the page's HTML text, where the frozen
  /// reader passes the parsed tree a JavaScript boundary cannot carry — a
  /// recorded divergence.
  Future<String> _documentValue(
    HtmlString? job,
    RuleField field,
    String content,
  ) async =>
      '${await field.apply(field.isScriptOnly ? content : job!.value) ?? ''}';

  /// One rule through the Rust adapter on its own, for the rule-field forms that
  /// need a value *before* the stage's batch is declared: a `@put:` value and a
  /// `{{$.x}}` interpolation. A field without those never reaches this, so the
  /// one-bridge-call-per-stage shape is kept for every page that does not use
  /// them.
  Future<Object?> _eagerExtract(Object? value, String rule) async {
    final batch = HtmlRuleBatch('$value');
    final job = batch.documentText('value', rule);
    await batch.run();
    final result = job.value;
    return result.isEmpty ? null : result;
  }

  /// The script segments of one rule field applied to each value the field's
  /// extraction produced.
  Future<List<String>> _perElement(
    RuleField field,
    List<String> values,
  ) async => [for (final value in values) '${await field.apply(value) ?? ''}'];

  /// The source fields a script can read, as the frozen `source` object exposes
  /// them, including the header rule that `source.getHeaderMap` evaluates.
  Map<String, Object?> get _sourceFields => {
    'bookSourceUrl': source['bookSourceUrl'],
    'bookSourceName': source['bookSourceName'],
    'bookSourceGroup': source['bookSourceGroup'],
    'bookSourceType': source['bookSourceType'],
    'bookSourceComment': source['bookSourceComment'],
    'header': source['header'],
    'enabledCookieJar': source['enabledCookieJar'],
    'loginUrl': source['loginUrl'],
  };

  Future<String> _expand(String template, String keyword) async {
    return expandSourceUrl(template, (expression, result) {
      // The frozen runtime evaluates `{{key}}` and `{{page}}` as JavaScript
      // bindings; a bare `key` or `page` therefore substitutes the raw value
      // and the request's query/body encoder does any escaping later.
      final trimmed = expression.trim();
      if (trimmed == 'key') return Future<Object?>.value(keyword);
      if (trimmed == 'page') return Future<Object?>.value(_page);
      return _evalJs(expression, keyword, result);
    }, page: _page);
  }

  /// Expands one rule, splits its URL options, and applies the `js` option.
  Future<(Uri, SourceUrlOptions)> _request(
    Uri base,
    String template,
    String keyword,
  ) async {
    final split = splitSourceUrlOptions(await _expand(template, keyword));
    final script = split.options.js;
    final text = script == null
        ? split.path
        : '${await _evalJs(script, keyword, '${_resolve(base, split.path, keepFragment: true)}')}';
    var url = _resolve(base, text, keepFragment: true);
    if (!split.options.isPost) {
      url = _resolve(
        base,
        await encodeSourceQuery(
          sourceUrlTextWithRawQuery(url, text),
          charset: split.options.charset,
        ),
      );
    }
    return (url, split.options);
  }

  /// Resolves an already-extracted rule value that may carry URL options.
  Future<(Uri, SourceUrlOptions)> _extracted(Uri base, String value) async {
    final split = splitSourceUrlOptions(value);
    var url = _resolve(base, split.path, keepFragment: true);
    if (!split.options.isPost) {
      url = _resolve(
        base,
        await encodeSourceQuery(
          sourceUrlTextWithRawQuery(url, split.path),
          charset: split.options.charset,
        ),
      );
    }
    return (url, split.options);
  }

  String _rule(String group, String key, {bool optional = false}) {
    final rules = source[group];
    final rule = rules is Map ? rules[key] : null;
    if (rule == null || rule == '') {
      if (optional) return '';
      throw FormatException('缺少 $group.$key');
    }
    if (rule is! String) {
      throw FormatException('$group.$key 必须是字符串规则');
    }
    return rule.isNotEmpty
        ? rule
        : (optional ? '' : (throw FormatException('缺少 $group.$key')));
  }

  /// A required extraction of one matched element.
  String _required(List<String> values, int index, String label) {
    final value = values[index];
    if (value.isEmpty) throw FormatException('$label 未匹配到内容');
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

  Future<(String, Uri)> _fetch(
    Uri url,
    BookSourceStage stage, {
    SourceUrlOptions options = const SourceUrlOptions(),
  }) async {
    _validate();
    final sourceHeaders = await _headers();
    final merged = {...sourceHeaders, ...options.headers};
    final (method: method, body: body, headers: extra) =
        await sourceRequestShape(options, merged);
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
    return (text, finalUrl);
  }

  @override
  Future<List<HtmlBook>> search(String keyword, {int page = 1}) async {
    _book = null;
    _chapter = null;
    _chapterTitle = null;
    _validate();
    // `ruleSearch.checkKeyWord` is a check keyword: the frozen readers of it are
    // the source check and the debug page's search box, not this stage, so a
    // search runs on the keyword it was given whatever the field holds.
    _page = page;
    _keyword = keyword;
    _chapterTitle = null;
    final base = SourceHttpUri.parse(source['bookSourceUrl'] as String);
    final (url, options) = await _request(
      base,
      source['searchUrl'] as String,
      keyword,
    );
    final (html, finalUrl) = await _fetch(
      url,
      BookSourceStage.search,
      options: options,
    );
    final batch = HtmlRuleBatch(html);
    final listRule = await _field(
      _rule('ruleSearch', 'bookList'),
      content: html,
      allowScripts: false,
    );
    final items = batch.elements('items', listRule.extractionRule!);
    final name = await _elementField(
      _rule('ruleSearch', 'name'),
      content: html,
    );
    final names = batch.elementsText('name', name.extractionRule!, items);
    final bookUrl = await _elementField(
      _rule('ruleSearch', 'bookUrl'),
      content: html,
    );
    final urls = batch.elementsText('url', bookUrl.extractionRule!, items);
    final author = await _elementField(
      _rule('ruleSearch', 'author', optional: true),
      content: html,
    );
    final authors = batch.elementsText('author', author.extractionRule!, items);
    final intro = await _elementField(
      _rule('ruleSearch', 'intro', optional: true),
      content: html,
    );
    final intros = batch.elementsText('intro', intro.extractionRule!, items);
    final lastChapter = await _elementField(
      _rule('ruleSearch', 'lastChapter', optional: true),
      content: html,
    );
    final lastChapters = batch.elementsText(
      'lastChapter',
      lastChapter.extractionRule!,
      items,
    );
    final wordCount = await _elementField(
      _rule('ruleSearch', 'wordCount', optional: true),
      content: html,
    );
    final wordCounts = batch.elementsText(
      'wordCount',
      wordCount.extractionRule!,
      items,
    );
    final kind = await _elementField(
      _rule('ruleSearch', 'kind', optional: true),
      content: html,
    );
    final kinds = batch.elementsText('kind', kind.extractionRule!, items);
    await batch.run();

    final titles = await _perElement(name, names.values);
    final links = await _perElement(bookUrl, urls.values);
    final authorValues = await _perElement(author, authors.values);
    final introValues = await _perElement(intro, intros.values);
    final lastChapterValues = await _perElement(
      lastChapter,
      lastChapters.values,
    );
    final wordCountValues = await _perElement(wordCount, wordCounts.values);
    final kindValues = await _perElement(kind, kinds.values);

    final books = <HtmlBook>[];
    for (var index = 0; index < items.length; index++) {
      final (bookUrlTarget, bookOptions) = await _extracted(
        finalUrl,
        _required(links, index, 'ruleSearch.bookUrl'),
      );
      _bookOptions[bookUrlTarget] = bookOptions;
      books.add(
        HtmlBook(
          url: bookUrlTarget,
          title: _required(titles, index, 'ruleSearch.name'),
          author: authorValues[index],
          intro: formatSourceIntro(introValues[index]),
          lastChapter: lastChapterValues[index],
          wordCount: formatSourceWordCount(wordCountValues[index]),
          kind: kindValues[index],
        ),
      );
    }
    return books;
  }

  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async {
    _book = hit;
    _chapter = null;
    _chapterTitle = null;
    _page = null;
    final (html, infoUrl) = await _fetch(
      hit.url,
      BookSourceStage.bookInfo,
      options: _bookOptions.remove(hit.url) ?? const SourceUrlOptions(),
    );
    final batch = HtmlRuleBatch(html);
    final name = await _field(_rule('ruleBookInfo', 'name'), content: html);
    final nameValue = _declare(batch, 'name', name);
    final author = await _field(
      _rule('ruleBookInfo', 'author', optional: true),
      content: html,
    );
    final authorValue = _declare(batch, 'author', author);
    final intro = await _field(
      _rule('ruleBookInfo', 'intro', optional: true),
      content: html,
    );
    final introValue = _declare(batch, 'intro', intro);
    final cover = await _field(
      _rule('ruleBookInfo', 'coverUrl', optional: true),
      content: html,
    );
    final coverValue = _declare(batch, 'cover', cover);
    final kind = await _field(
      _rule('ruleBookInfo', 'kind', optional: true),
      content: html,
    );
    final kindValue = _declare(batch, 'kind', kind);
    final lastChapter = await _field(
      _rule('ruleBookInfo', 'lastChapter', optional: true),
      content: html,
    );
    final lastChapterValue = _declare(batch, 'lastChapter', lastChapter);
    final wordCount = await _field(
      _rule('ruleBookInfo', 'wordCount', optional: true),
      content: html,
    );
    final wordCountValue = _declare(batch, 'wordCount', wordCount);
    final canReName = _rule(
      'ruleBookInfo',
      'canReName',
      optional: true,
    ).trim().isNotEmpty;
    final tocUrl = await _field(_rule('ruleBookInfo', 'tocUrl'), content: html);
    final tocValue = _declare(batch, 'tocUrl', tocUrl);
    await batch.run();

    final coverText = await _documentValue(coverValue, cover, html);
    final detailsTitle = await _documentValue(nameValue, name, html);
    final detailsAuthor = await _documentValue(authorValue, author, html);
    final detailsLastChapter = await _documentValue(
      lastChapterValue,
      lastChapter,
      html,
    );
    final detailsWordCount = formatSourceWordCount(
      await _documentValue(wordCountValue, wordCount, html),
    );
    final detailsIntro = formatSourceIntro(
      await _documentValue(introValue, intro, html),
    );
    final book = HtmlBook(
      url: hit.url,
      // Legado only permits a detail page to replace the search title/author
      // when `canReName` is declared (BookInfo.kt:65-70).
      title: detailsTitle.isNotEmpty && (canReName || hit.title.isEmpty)
          ? detailsTitle
          : hit.title,
      author: detailsAuthor.isNotEmpty && (canReName || hit.author.isEmpty)
          ? detailsAuthor
          : hit.author,
      intro: detailsIntro.isEmpty ? hit.intro : detailsIntro,
      cover: coverText.isEmpty ? '' : '${_resolve(infoUrl, coverText)}',
      kind: await _documentValue(kindValue, kind, html),
      lastChapter: detailsLastChapter.isEmpty
          ? hit.lastChapter
          : detailsLastChapter,
      wordCount: detailsWordCount.isEmpty ? hit.wordCount : detailsWordCount,
    );
    _book = book;
    final (tocTarget, tocOptions) = await _extracted(
      infoUrl,
      await _documentValue(tocValue, tocUrl, html),
    );
    var url = tocTarget;
    var options = tocOptions;
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
      final batch = HtmlRuleBatch(page);
      final listRule = await _field(
        _rule('ruleToc', 'chapterList'),
        content: page,
        allowScripts: false,
      );
      final items = batch.elements('items', listRule.extractionRule!);
      final name = await _elementField(
        _rule('ruleToc', 'chapterName'),
        content: page,
      );
      final names = batch.elementsText('name', name.extractionRule!, items);
      final urlField = await _elementField(
        _rule('ruleToc', 'chapterUrl'),
        content: page,
      );
      final urls = batch.elementsText('url', urlField.extractionRule!, items);
      final next = await _field(
        _rule('ruleToc', 'nextTocUrl', optional: true),
        content: page,
      );
      final nextValue = _declare(batch, 'next', next);
      await batch.run();
      if (items.isEmpty) throw StateError('目录页为空');
      final names2 = await _perElement(name, names.values);
      final urls2 = await _perElement(urlField, urls.values);
      final nextText = await _documentValue(nextValue, next, page);
      for (var index = 0; index < items.length; index++) {
        final (chapterUrl, chapterOptions) = await _extracted(
          pageUrl,
          _required(urls2, index, 'ruleToc.chapterUrl'),
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
          SourceChapter(
            _required(names2, index, 'ruleToc.chapterName'),
            chapterUrl,
          ),
        );
      }
      if (nextText.isEmpty) break;
      final (nextUrl, nextOptions) = await _extracted(pageUrl, nextText);
      url = nextUrl;
      options = nextOptions;
    }
    return (book, chapters);
  }

  /// `ruleContent.content` with the source's `replaceRegex` field appended.
  ///
  /// The frozen content rule carries the replacement as its own field and the
  /// `##` machinery applies it to the extracted text; appending it keeps that
  /// behaviour inside the adapter instead of re-implementing it here.
  String _contentRule(SourceChapter chapter) {
    final content = _rule('ruleContent', 'content');
    final replacement = _rule(
      'ruleContent',
      'replaceRegex',
      optional: true,
    ).replaceAll('{{chapter.title}}', chapter.name);
    if (replacement.contains('{{')) {
      throw UnsupportedError('暂不支持该正文替换表达式');
    }
    if (replacement.isEmpty) return content;
    if (content.contains('##')) {
      throw UnsupportedError('暂不支持同时使用正文替换和规则内替换');
    }
    return '$content$replacement';
  }

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
  }) async {
    if (book != null) _book = book;
    _chapter = chapter;
    _page = null;
    _chapterTitle = chapter.name;
    var url = chapter.url;
    final visited = <Uri>{};
    final parts = <String>[];
    String? contentTitle;
    var retry = 0;
    while (true) {
      if (!visited.add(url) || visited.length > 20) {
        throw StateError('正文分页循环或超出 20 页');
      }
      final (html, pageUrl) = await _fetch(
        url,
        BookSourceStage.content,
        options: SourceUrlOptions(retry: retry),
      );
      // Frozen BookContent applies the first-page title before parsing content
      // rules: their scripts and {{chapter.title}} see the updated value.
      if (parts.isEmpty) {
        final titleRule = _rule('ruleContent', 'title', optional: true);
        if (titleRule.trim().isNotEmpty) {
          final title = await _field(titleRule, content: html);
          final titleBatch = HtmlRuleBatch(html);
          final titleValue = _declare(titleBatch, 'title', title);
          await titleBatch.run();
          final extracted = await _documentValue(titleValue, title, html);
          if (extracted.trim().isNotEmpty) {
            contentTitle = _chapterTitle = extracted;
            _chapter = SourceChapter(extracted, chapter.url);
          }
        }
      }
      final content = await _field(
        _contentRule(SourceChapter(_chapterTitle!, chapter.url)),
        content: html,
      );
      final next = await _field(
        _rule('ruleContent', 'nextContentUrl', optional: true),
        content: html,
      );
      final batch = HtmlRuleBatch(html);
      final contentValue = _declare(batch, 'content', content);
      final nextValue = _declare(batch, 'next', next);
      await batch.run();
      final text = await _documentValue(contentValue, content, html);
      if (text.isEmpty) {
        throw const FormatException('ruleContent.content 未匹配到内容');
      }
      parts.add(text);
      final nextText = await _documentValue(nextValue, next, html);
      if (nextText.isEmpty) break;
      final (nextUrl, nextOptions) = await _extracted(pageUrl, nextText);
      if (nextOptions.isPost ||
          nextOptions.body != null ||
          nextOptions.headers.isNotEmpty ||
          nextOptions.js != null) {
        throw UnsupportedError('暂不支持正文分页地址的 URL 选项');
      }
      retry = nextOptions.retry;
      url = nextUrl;
    }
    return HtmlChapterBody(
      _shapeJoinedContent(parts.join('\n')),
      visited.length,
      title: contentTitle,
    );
  }

  /// The frozen content stage's final shaping (`BookContent.kt:135-142`).
  ///
  /// Only when the source declares `ruleContent.replaceRegex` does the frozen
  /// stage shape the joined page text: it trims every line, runs the
  /// replacement over the whole text, and prefixes every line — an empty line
  /// included — with the hard-coded two full-width spaces `"　　"`. The
  /// replacement itself already ran for each page inside [_contentRule]'s
  /// appended `##` rule, so this step trims and prefixes the joined result; the
  /// frozen code trims before it replaces, so a pattern that matches whitespace
  /// the trim would remove is the one case the two orders can diverge, and the
  /// marker this corpus declares is unaffected. A source that declares no
  /// `replaceRegex` is left exactly as extracted.
  String _shapeJoinedContent(String text) {
    if (_rule('ruleContent', 'replaceRegex', optional: true).isEmpty) {
      return text;
    }
    return text.split('\n').map((line) => '　　${line.trim()}').join('\n');
  }
}
