import 'dart:convert';
import 'dart:typed_data';

import '../domain/contracts.dart';
import '../domain/store_message.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'book_source_webview_adapter.dart';
import 'java_regex.dart';
import 'json_source_rules.dart';
import 'js_source_runtime.dart';
import 'rule_field.dart';
import 'source_host_dispatcher.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';
import 'source_page_results.dart';
import 'source_url_rules.dart';

/// A stage whose response body is not the JSON that stage's rules read: the
/// source got an HTML error page, a challenge page or an empty body where it
/// expected its document.
///
/// The frozen reader fails inside Gson and its exception names a character
/// offset, and this product's raw `FormatException` did the same, so the
/// operator saw `读取失败：FormatException: Unexpected character (at character 1)`
/// with the body pasted on and nothing about which stage, which request or
/// which body produced it. This error carries what the caller can act on.
class SourceStageFormatError implements Exception {
  const SourceStageFormatError({
    required this.stage,
    required this.address,
    required this.prefix,
  });

  /// The stage whose response could not be read.
  final BookSourceStage stage;

  /// The response's address, without the parts a source's credentials travel in
  /// (see [sourceStageAddress]).
  final String address;

  /// A bounded, single-line prefix of the body (see [sourceStageBodyPrefix]).
  final String prefix;

  /// The stage's word as this product's copy uses it (`详情` for the book
  /// information stage, the word `readingDetailsAndToc` already shows). No stage
  /// outside the four that read a body decodes one, so the remaining stages keep
  /// their identifier rather than inventing a word.
  static String stageWord(BookSourceStage stage) => switch (stage) {
    BookSourceStage.search => '搜索',
    BookSourceStage.bookInfo => '详情',
    BookSourceStage.tableOfContents => '目录',
    BookSourceStage.content => '正文',
    BookSourceStage.idle ||
    BookSourceStage.completed ||
    BookSourceStage.failed => stage.name,
  };

  @override
  String toString() =>
      '${stageWord(stage)}响应不是 JSON（可能是错误页）：$prefix（$address）';
}

/// How much of a body [SourceStageFormatError] keeps: enough to recognize an
/// error page, not a body to read. A whole body belongs in the source's own log
/// and in nothing the interface shows.
const sourceStageBodyPrefixLimit = 40;

/// A body's first [sourceStageBodyPrefixLimit] characters as one line, the last
/// of them an ellipsis when the body continues. A newline in the body would put
/// the rest of the page on its own line in a status message, so whitespace runs
/// collapse first.
String sourceStageBodyPrefix(String body) {
  final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= sourceStageBodyPrefixLimit) return text;
  return '${text.substring(0, sourceStageBodyPrefixLimit - 1)}…';
}

/// The response's address as a diagnostic may show it: the scheme, host, port
/// and path, without the query or any user info. A source's key, token or
/// credential commonly travels in the query, and a message the operator can
/// paste or screenshot must not carry it.
String sourceStageAddress(Uri url) => Uri(
  scheme: url.scheme,
  host: url.host,
  port: url.hasPort ? url.port : null,
  path: url.path,
).toString();

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
    this.webViewFactory,
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

  /// The rendered-document adapter factory this pipeline's WebView stages use.
  /// Null builds the platform one for this source; a test substitutes its own,
  /// because the pipeline's choice of path is what it checks.
  final BookSourceWebViewAdapterFactory? webViewFactory;

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

  /// The chapter whose title the frozen `AnalyzeRule` binds as `title` while the
  /// content stage runs; null in every other stage, exactly as `chapter?.title`
  /// is there. Book/chapter snapshots carry only existing stage result fields.
  String? _chapterTitle;

  /// The next chapter's URL while the content stage runs — the frozen
  /// `AnalyzeRule.nextChapterUrl` (`AnalyzeRule.kt:58,761`), bound for that
  /// stage's rules and read by its own next-content guard. Null when the caller
  /// has no next chapter.
  String? _nextChapterUrl;
  HtmlBook? _book;
  SourceChapter? _chapter;

  /// The frozen `AnalyzeUrl` options one analysis owns: a book URL's address
  /// text, the base it resolved against and the options it carried, kept for
  /// the stage that fetches it, because a book URL is handed around without
  /// them. A *chapter*'s options do not need this map: the chapter keeps its
  /// own address text, so they survive the hand-off and a restart, and a book
  /// keeps its own too ([HtmlBook.rawAddress]) — what this map still holds for
  /// a search hit is the response URL its address resolved against (#97).
  final _bookRequests =
      <Uri, ({String address, Uri base, SourceUrlOptions options})>{};

  /// The request the stage currently running made: what the stage's
  /// `loginCheckJs` repeats through `java.getStrResponse`/`java.getResponse` and
  /// re-analyzes through `java.initUrl` (the frozen check script's `java` is the
  /// stage's own `AnalyzeUrl`). [BookSourceStage] is only the trace entry such a
  /// repeat records.
  ({
    Uri url,
    BookSourceStage stage,
    SourceUrlOptions options,
    String address,
    Uri base,
  })?
  _stageRequest;

  final _cancellation = SourceCancellation();

  @override
  final trace = <BookSourceTraceEntry>[];

  late final SourceHostState _hostSurface = hostState ?? SourceHostState();

  late final BookSourceWebViewAdapterFactory _webViewAdapter =
      webViewFactory ??
      BookSourceWebViewAdapterFactory(
        sourceRef: _sourceRef,
        hostState: _hostSurface,
        // The frozen `BackstageWebView.setCookie` writes what a finished page
        // left in the native store under the source's key; the source-scoped jar
        // is where this product keeps it (ADR 0011 §3).
        onPageCookies: (pageUrl, cookies) =>
            _hostSurface.cookiesFor(_sourceRef).set(pageUrl, cookies),
      );

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

  late final SourceScriptRuntime _runtime = InProcessSourceScriptRuntime(
    jsLib: source['jsLib'] as String? ?? '',
    dispatcher: _host,
    hostState: _hostSurface,
    androidId: androidId,
    onMessage: (message) => onHostMessage?.call(message),
    ruleEvaluator: _readScriptRule,
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
    'header': source['header'],
    'enabledCookieJar': source['enabledCookieJar'],
    'loginUrl': source['loginUrl'],
  };

  Map<String, Object?> _scriptInput(
    String keyword,
    Object? result, {
    Object? content,
  }) => {
    'sourceKey': _sourceRef,
    'source': _sourceFields,
    'key': keyword,
    'page': _page,
    'baseUrl': '$_base',
    'result': result,
    // The frozen `AnalyzeRule.evalJS` binds the analysis's own content as `src`
    // (`AnalyzeRule.kt:759`): it is the content the field being read carries, so
    // `java.getString` and its siblings read the object this field's own rule
    // read used when the source passes no content of its own.
    'src': ?content,
    'title': _chapterTitle,
    'nextChapterUrl': _nextChapterUrl,
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
    'headers': _activeHeaders,
  };

  /// One script this adapter runs. [label] is the rule field whose value the
  /// script belongs to (`ruleBookInfo.kind`); a failure carries it, so the field
  /// is named where the failure reaches the interface. A URL template's
  /// `{{...}}`, a URL option's `js` and the `header` rule are not rule fields
  /// and pass no label.
  Future<Object?> _evalJs(
    String script,
    String keyword,
    Object? result, {
    String label = '',
    Object? content,
  }) async {
    try {
      return await _runtime.evaluate(
        source: script,
        input: _scriptInput(keyword, result, content: content),
        timeout: const Duration(seconds: 30),
        cancellation: _cancellation,
      );
    } on SourceScriptError catch (error) {
      throw error.inRuleField(label);
    }
  }

  /// The frozen `res = analyzeUrl.evalJS(checkJs, res) as StrResponse`
  /// (`WebBook.kt:71` and its four siblings): the source's `loginCheckJs` after
  /// one stage response, with that response as the script's `result`, and the
  /// response the script returns in its place for the rest of the stage.
  ///
  /// The hook runs once per stage, on the stage's first response — the frozen
  /// call sites are the four stage entries, and the `nextTocUrl`/
  /// `nextContentUrl` pages `BookChapterList`/`BookContent` fetch never run it.
  Future<SourceStageResponse> _loginCheck(SourceStageResponse response) async {
    final checkJs = '${source['loginCheckJs'] ?? ''}';
    if (checkJs.trim().isEmpty) return response;
    return _runtime.evaluateLoginCheck(
      script: checkJs,
      input: _scriptInput(_keyword, response.toJson()),
      stage: SourceStageRequest(
        resend: _resendStage,
        reanalyze: _reanalyzeStage,
      ),
      timeout: const Duration(seconds: 30),
      cancellation: _cancellation,
    );
  }

  /// Frozen `AnalyzeUrl.getStrResponse` (`AnalyzeUrl.kt:465`): the stage's own
  /// request, with its own options and headers, sent again.
  Future<SourceStageResponse> _resendStage() {
    final stage = _stageRequest!;
    return _fetch(
      stage.stage,
      stage.url,
      options: stage.options,
      address: stage.address,
      base: stage.base,
    );
  }

  /// Frozen `AnalyzeUrl.initUrl` (`AnalyzeUrl.kt:139`): the stage's address text
  /// expanded and its options parsed again, so a request after the check uses
  /// the result.
  Future<void> _reanalyzeStage() async {
    final stage = _stageRequest!;
    final (url, options) = await _request(
      stage.base,
      stage.address,
      _keyword,
    );
    _stageRequest = (
      url: url,
      stage: stage.stage,
      options: options,
      address: stage.address,
      base: stage.base,
    );
  }

  /// The shared rule-field path's edges for this adapter: the scripts go through
  /// the runtime the adapter already owns, a value rule is extracted by the
  /// bounded JSON reader, and `@get:`/`@put:` read and write the source-scoped
  /// variables `java.get`/`java.put` use.
  ///
  /// [label] is the rule field being read (`ruleBookInfo.kind`): a script this
  /// field runs carries it into the failure it reports, so the interface and the
  /// source log name the field instead of the bare `js`.
  RuleFieldContext _ruleContext(String label, Object? content) =>
      RuleFieldContext(
        evaluateScript: (script, result) =>
            _evalJs(script, _keyword, result, label: label, content: content),
        extract: (value, rule) async => JsonSourceRules.extract(value, rule),
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

  /// One rule field through the shared path: `@js:`/`<js>` split,
  /// `{{...}}`/`@get:`/`@put:` resolved, then the JSON reader's extraction, then
  /// the script segments' value. [label] names the field, for a script failure.
  ///
  /// [raw] reads the extracted value itself instead of its text. It exists for
  /// the one rule whose answer is a *document* rather than a field: the frozen
  /// `ruleBookInfo.init` moves the content the remaining rules read into a
  /// subtree of the response, and text-rendering that subtree collapses it — a
  /// `{{$.novelId}}` in `tocUrl` then reads a String and finds nothing (the
  /// operator's 大道飘渺, whose `init` is `$.data`). The frozen keeps the object:
  /// `AnalyzeRule.setContent` takes the rule's result as the content whatever it
  /// is.
  Future<Object?> _field(
    Object? value,
    String rule, {
    String label = '',
    bool raw = false,
  }) async {
    final field = await RuleField.resolve(
      rule,
      _ruleContext(label, value),
      content: value,
    );
    final extracted = field.isScriptOnly
        ? value
        : raw
        ? JsonSourceRules.read(value, field.extractionRule!)
        : JsonSourceRules.extract(value, field.extractionRule!);
    return field.apply(extracted);
  }

  /// One element-list rule (`ruleSearch.bookList`/`ruleToc.chapterList`): the
  /// `{{...}}`/`@get:` substitution applies, a script does not — an element set
  /// is not a value this path can hand back, so a script there is refused by
  /// name instead of being dropped.
  Future<List<Object?>> _elementList(
    Object? value,
    String rule, {
    String label = '',
  }) async {
    final field = await RuleField.resolve(
      rule,
      _ruleContext(label, value),
      content: value,
    );
    if (field.scripts.isNotEmpty) {
      throw UnsupportedError('暂不支持列表规则里的 JavaScript：$rule');
    }
    return JsonSourceRules.list(value, field.extractionRule!);
  }

  /// One required value rule.
  Future<String> _text(Object? value, String rule, {String label = ''}) async {
    final result = await _field(value, rule, label: label);
    if (result == null || result.toString().isEmpty) {
      throw FormatException('Missing JSON value for $rule');
    }
    return result.toString();
  }

  /// One optional value rule: an empty rule or a missing value is an empty
  /// string. A rule that cannot be run at all still throws, so a broken rule is
  /// reported instead of disappearing.
  Future<String> _optional(
    Object? value,
    String rule, {
    String label = '',
  }) async {
    if (rule.trim().isEmpty) return '';
    return '${await _field(value, rule, label: label) ?? ''}';
  }

  /// One `java.getString`/`getStringList`/`getElement`/`getElements` call from a
  /// rule script — the frozen `AnalyzeRule.getString` and its three siblings
  /// (`AnalyzeRule.kt:159,166,246,252,259,328,363`) — read by *this* adapter's
  /// rule path over the content object the member was given: the same
  /// `RuleField`/`JsonSourceRules` read this stage reads its own fields with,
  /// not a second engine (ADR 0012).
  ///
  /// The frozen list and element forms are the JSON reader's own reads:
  /// `getStringList` is `AnalyzeByJSonPath.getStringList` (one text per match),
  /// `getElement` its `getObject` and `getElements` its `getList`
  /// (`AnalyzeByJSonPath.kt:79-154`). A rule that carries a script segment in
  /// those three forms refuses by name, as this adapter's element-list fields
  /// do: the frozen answers such a rule with the script's value re-read as a
  /// document, which this reader does not do.
  Future<Object?> _readScriptRule(SourceRuleRead read) async {
    final field = await RuleField.resolve(
      read.rule,
      _ruleContext(read.member, read.content),
      content: read.content,
    );
    if (read.form != SourceRuleForm.string && field.scripts.isNotEmpty) {
      throw SourceScriptError(
        'policy',
        '${read.member} 暂不支持带脚本的列表/元素规则：${read.rule}',
      );
    }
    switch (read.form) {
      case SourceRuleForm.string:
        final extracted = field.isScriptOnly
            ? read.content
            : JsonSourceRules.extract(read.content, field.extractionRule!);
        return '${await field.apply(extracted) ?? ''}';
      case SourceRuleForm.stringList:
        return [
          for (final value in JsonSourceRules.list(
            read.content,
            field.extractionRule!,
          ))
            '$value',
        ];
      case SourceRuleForm.element:
        return JsonSourceRules.read(read.content, field.extractionRule!);
      case SourceRuleForm.elements:
        return JsonSourceRules.list(read.content, field.extractionRule!);
    }
  }

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
    // The frozen `BaseSource.getHeaderMap` answers no headers for a `header`
    // rule it cannot read (lenient Gson, and every failure caught), so a rule
    // whose text is not a JSON map runs on no *source* headers instead of
    // refusing the source; the request then carries the source's declared
    // headers only where the rule parsed.
    final sourceHeaders = parseSourceHeaderMap(json);
    if (sourceHeaders == null) return {...headers};
    if (sourceHeaders.keys.any((key) => key.toLowerCase() == 'proxy')) {
      throw UnsupportedError('暂不支持代理配置');
    }
    return {...sourceHeaders, ...headers};
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
    // The frozen replaces the URL with the option script's result only when that
    // result is not null (`AnalyzeUrl.kt:238-242`: `evalJS(jsStr, url)
    // ?.toString()?.let { url = it }`). A script that only shows a toast answers
    // nothing, so the URL it was given stands — stringifying that nothing into
    // `'null'` sent the request to `/null` (a real source's search, #94).
    final text = script == null
        ? split.path
        : (await _evalJs(script, keyword, '$url'))?.toString() ?? split.path;
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

  /// Sends one stage request and answers the stage response as the JSON rules
  /// and the stage's `loginCheckJs` read it: the raw body, not the decoded
  /// document, because the frozen rules parse the `StrResponse` body and a
  /// check script may replace it.
  ///
  /// [address] is the address text this request came from and [base] the URL it
  /// resolved against; both are kept for `java.initUrl`, which re-runs the
  /// address analysis (`SourceStageRequest.reanalyze`). A caller that only has
  /// the resolved URL passes neither: the URL text is then the address.
  Future<SourceStageResponse> _fetch(
    BookSourceStage stage,
    Uri url, {
    SourceUrlOptions options = const SourceUrlOptions(),
    String? address,
    Uri? base,
  }) async {
    _stageRequest = (
      url: url,
      stage: stage,
      options: options,
      address: address ?? '$url',
      base: base ?? url,
    );
    _cancellation.throwIfCancelled();
    final merged = {..._activeHeaders, ...options.headers};
    final (method: method, body: body, headers: extra) =
        await sourceRequestShape(options, merged);
    final headers = {...merged, ...extra};
    final host = _host;
    if (options.webView) {
      // The frozen `AnalyzeUrl` WebView path, under this source's rate limit: a
      // JSON source's `webJs` is what produces the JSON this stage reads.
      Future<({String body, Uri url})> render() => loadSourceWebView(
        factory: _webViewAdapter,
        options: options,
        url: url,
        method: method,
        headers: headers,
        cancellation: _cancellation,
        bootstrap: () => host!
            .forExecution(_cancellation)
            .request(method, '$url', headers: headers, body: body),
      );
      final result = host == null
          ? await render()
          : await host
                .forExecution(_cancellation)
                .withSourceRateLimit(render);
      trace.add(BookSourceTraceEntry(stage: stage, path: url.toString()));
      _cancellation.throwIfCancelled();
      // A rendered document has no HTTP response of its own: the frozen
      // `StrResponse(url, body)` reports status 200 and no headers.
      return SourceStageResponse.webView(body: result.body, url: result.url);
    }
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
      return SourceStageResponse(
        body: response.body,
        url: response.url,
        statusCode: response.statusCode,
        headers: response.headers,
      );
    }
    if (method != 'GET' || headers.isNotEmpty) {
      throw UnsupportedError('当前 transport 不支持 HTTP 请求选项');
    }
    final text = await transport.request(stage: stage, path: url.toString());
    trace.add(BookSourceTraceEntry(stage: stage, path: url.toString()));
    _cancellation.throwIfCancelled();
    return SourceStageResponse(body: text, url: url);
  }

  /// One stage response's document: the JSON its rules read.
  ///
  /// A body that is not JSON is a stage failure that says so — the stage, the
  /// response's address and a bounded prefix of the body — instead of the
  /// decoder's `FormatException`, which names one character and nothing about
  /// the request that produced it (ticket #89).
  Object? _document(BookSourceStage stage, SourceStageResponse response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw SourceStageFormatError(
        stage: stage,
        address: sourceStageAddress(response.url),
        prefix: sourceStageBodyPrefix(response.body),
      );
    }
  }

  /// The rule map of one stage, refusing an unsupported rule by name.
  Map<String, String> _rules(String key, List<String> required) {
    final raw = source[key];
    if (raw is! Map) throw FormatException('Missing $key');
    final rules = <String, String>{};
    for (final entry in raw.entries) {
      if (entry.value == null || entry.value == '') continue;
      if (entry.value is! String) {
        throw FormatException('Invalid $key.${entry.key}');
      }
      // `downloadUrls` is declared by real sources and read by the frozen into
      // `book.downloadUrls`; this product defers downloads (ADR 0011 §4), so the
      // field is accepted and ignored. Validating it as an extraction refused a
      // whole details stage for a field nothing executes — the operator's real
      // run hit it on a source whose `ruleBookInfo.downloadUrls` is a bare URL
      // (万生痴魔's source, batch 17).
      if (entry.key == 'downloadUrls') continue;
      // The page-chaining pair is the one per-*stage* allowance: `nextTocUrl`
      // belongs to `ruleToc` and `nextContentUrl` to `ruleContent`, and each
      // group still refuses the other's field by name. Both are read as lists
      // (`AnalyzeRule.getStringList`), so they validate like a list rule.
      final chained =
          (key == 'ruleToc' && entry.key == 'nextTocUrl') ||
          (key == 'ruleContent' && entry.key == 'nextContentUrl');
      // `imageStyle` is a *value* this tree already reads off the source
      // (`sourceImageStyle`), and `replaceRegex` is a frozen content-stage field
      // this product does not execute on the JSON path; neither is an
      // extraction, so neither is validated as one. Refusing either refused the
      // whole group — the same defect #81 fixed for `downloadUrls` (the
      // operator's audit, #82/#83).
      if (entry.key != 'checkKeyWord' &&
          entry.key != 'canReName' &&
          entry.key != 'imageStyle' &&
          entry.key != 'replaceRegex') {
        // Every declared extraction field is checked, including optional
        // result fields: malformed rules fail with their field context.
        final extraction = RuleField.extractionText(entry.value as String);
        try {
          if (extraction != null) {
            JsonSourceRules.validate(
              extraction,
              forList:
                  entry.key == 'bookList' ||
                  entry.key == 'chapterList' ||
                  chained,
            );
          }
        } on UnsupportedError catch (error) {
          throw UnsupportedError('$key.${entry.key}: $error');
        }
      }
      if (!required.contains(entry.key) &&
          !chained &&
          !{
            'author',
            'coverUrl',
            'intro',
            'kind',
            'wordCount',
            'lastChapter',
            'updateTime',
            'isVolume',
            'isVip',
            'isPay',
            'canReName',
            'downloadUrls',
            'imageStyle',
            'replaceRegex',
            'init',
            'checkKeyWord',
            'title',
            // `ruleBookInfo.name` and `ruleBookInfo.tocUrl` are optional in the
            // frozen app: an empty `name` keeps the book's existing title
            // (`BookInfo.kt:64-70`) and an empty `tocUrl` means the book's own
            // address (`BookInfo.kt:150-152`). A source that declares neither is
            // read, not refused — the operator's real run found the refusal
            // (batch 17).
            'name',
            'tocUrl',
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

  /// `ruleSearch`: the books a keyword search returns.
  @override
  Future<List<HtmlBook>> search(String keyword, {int page = 1}) async {
    _book = null;
    _chapter = null;
    _chapterTitle = null;
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
    final checked = await _loginCheck(
      await _fetch(
        BookSourceStage.search,
        url,
        options: options,
        address: source['searchUrl'] as String,
        base: _base,
      ),
    );
    final document = _document(BookSourceStage.search, checked);
    final finalUrl = checked.url;
    final bookUrlPattern = '${source['bookUrlPattern'] ?? ''}';
    // The frozen search stage asks first whether the response is a book detail
    // page, and returns that one book when it is; the element-list rules below
    // are never evaluated over the response (`BookList.kt:53-70`).
    if (bookUrlPattern.isNotEmpty &&
        javaMatchesWhole(
          bookUrlPattern,
          '$finalUrl',
          label: 'bookUrlPattern',
        )) {
      return _detailPageBooks(document, finalUrl);
    }
    final found = await _elementList(
      document,
      search['bookList']!,
      label: 'ruleSearch.bookList',
    );
    // The frozen companion to the branch above: an empty element list and no
    // `bookUrlPattern` mean the page is a detail page too (`BookList.kt:88-99`).
    if (found.isEmpty && bookUrlPattern.isEmpty) {
      return _detailPageBooks(document, finalUrl);
    }
    final books = <HtmlBook>[];
    for (final entry in found) {
      // A book URL is resolved against the search request's own URL, the way the
      // frozen `AnalyzeUrl` chains its stages, and keeps the options it carried
      // for the details fetch. The URL keeps the adapter's existing
      // `template` + `expandSourceUrl` path: the request-time substitution and
      // the `,{...}` options are that path's, not the rule-field path's.
      final bookAddress = JsonSourceRules.template(entry, search['bookUrl']!);
      final (bookUrl, bookOptions) = await _request(
        checked.url,
        bookAddress,
        keyword,
      );
      _bookRequests[bookUrl] = (
        address: bookAddress,
        base: finalUrl,
        options: bookOptions,
      );
      final name = await _text(
        entry,
        search['name']!,
        label: 'ruleSearch.name',
      );
      final author = await _optional(
        entry,
        search['author'] ?? '',
        label: 'ruleSearch.author',
      );
      final intro = await _optional(
        entry,
        search['intro'] ?? '',
        label: 'ruleSearch.intro',
      );
      final lastChapter = await _optional(
        entry,
        search['lastChapter'] ?? '',
        label: 'ruleSearch.lastChapter',
      );
      final wordCount = await _optional(
        entry,
        search['wordCount'] ?? '',
        label: 'ruleSearch.wordCount',
      );
      books.add(
        HtmlBook(
          url: bookUrl,
          // The rule's own text: the address a shelf row keeps and a later
          // fetch parses (#97).
          rawAddress: bookAddress,
          title: name,
          author: author,
          intro: formatSourceIntro(intro),
          lastChapter: lastChapter,
          wordCount: formatSourceWordCount(wordCount),
          kind: await _optional(
            entry,
            search['kind'] ?? '',
            label: 'ruleSearch.kind',
          ),
        ),
      );
    }
    return books;
  }

  /// `ruleBookInfo` plus `ruleToc`: the book's own page and its chapter list.
  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async {
    _book = hit;
    _chapter = null;
    _chapterTitle = null;
    _validate();
    _page = null;
    _activeHeaders = await _ensureHeaders();
    final info = _rules('ruleBookInfo', const []);
    final toc = _rules('ruleToc', ['chapterList', 'chapterName', 'chapterUrl']);
    final bookRequest = _bookRequests.remove(hit.url);
    // The book's own address text is what this request analyzes, the way the
    // frozen details stage analyzes `book.bookUrl` (`WebBook.kt:163-169`): the
    // request targets the text before its option tail and carries the options
    // it found, so a stored address's `,{…}` tail never reaches the site as
    // percent-encoded query text (#97). A search hit already resolved its
    // address against the search response, so it keeps the request it made; a
    // book rebuilt from the store or from a pasted address has only the text,
    // which resolves against the source's own URL as it does there. The frozen
    // stage binds no key and no page, so a stored address's `{{key}}`/`{{page}}`
    // bind nothing here either.
    final (bookUrl, bookOptions) = bookRequest == null
        ? await _request(_base, hit.address, '')
        : (hit.url, bookRequest.options);
    final bookInfo = await _loginCheck(
      await _fetch(
        BookSourceStage.bookInfo,
        bookUrl,
        options: bookOptions,
        address: bookRequest?.address ?? hit.address,
        base: bookRequest?.base ?? _base,
      ),
    );
    final document = _document(BookSourceStage.bookInfo, bookInfo);
    final (book, page) = await _readBookInfo(document, hit, info);
    final tocAddress = JsonSourceRules.template(page, info['tocUrl'] ?? '');
    // An empty `tocUrl` resolves to the book's own address, which is the frozen
    // fallback (`BookInfo.kt:150-152`), whose options that request parses again.
    final (tocUrl, tocOptions) = tocAddress.isEmpty
        ? (bookUrl, bookOptions)
        : await _request(hit.url, tocAddress, _keyword);
    final chapters = <SourceChapter>[];
    // The frozen 猫眼 rule names `java.aesBase64DecodeToString`, which is outside
    // the approved host surface (#10, ADR 0011), so the rule field cannot run
    // the script: the adapter reads the JSONPath and decrypts with the **rule's
    // own** key and iv here. The script is not dropped — it is answered by name.
    //
    // The key and iv come from the rule text rather than a constant: the two
    // 猫眼 sources in the operator's library use different keys
    // (`f041c49714d39908` / `4395daa50ad6baf7`), and a hard-coded pair decrypted
    // one of them into garbage ("Invalid AES-CBC padding", 大道飘渺, #94).
    final catEye = catEyeAesArguments(toc['chapterUrl']!);
    var firstPage = true;
    // The frozen page walk (`BookChapterList.kt:48-121`), the same one the HTML
    // adapter runs: this page, then the pages its `nextTocUrl` list declares.
    await walkSourcePages(
      first: (
        url: tocUrl,
        options: tocOptions,
        address: tocAddress,
        base: hit.url,
      ),
      maxPages: 30,
      cycleError: 'TOC page cycle',
      // The frozen drops an item equal to the page it was read from
      // (`BookChapterList.kt:96-100`).
      dropSelf: true,
      resolve: (address, pageUrl) async {
        final (url, options) = await _request(pageUrl, address, _keyword);
        return (url: url, options: options);
      },
      visit: (request, {required readNext}) async {
        var tocPage = await _fetch(
          BookSourceStage.tableOfContents,
          request.url,
          options: request.options,
          address: request.address,
          base: request.base,
        );
        // The frozen TOC stage checks login once, on its first response
        // (`WebBook.kt:253`); the `nextTocUrl` pages never run the check.
        if (firstPage) {
          tocPage = await _loginCheck(tocPage);
          firstPage = false;
        }
        final document = _document(BookSourceStage.tableOfContents, tocPage);
        final entries = await _elementList(
          document,
          toc['chapterList']!,
          label: 'ruleToc.chapterList',
        );
        for (var index = 0; index < entries.length; index++) {
          final entry = entries[index];
          // The frozen adds a chapter only when its title is non-empty
          // (`BookChapterList.kt:244`), so an element the name rule matched nothing
          // on is skipped instead of failing the whole TOC.
          final name = await _optional(
            entry,
            toc['chapterName']!,
            label: 'ruleToc.chapterName',
          );
          if (name.isEmpty) continue;
          final tag = await _optional(
            entry,
            toc['updateTime'] ?? '',
            label: 'ruleToc.updateTime',
          );
          final isVolume = sourceIsTrue(
            await _optional(
              entry,
              toc['isVolume'] ?? '',
              label: 'ruleToc.isVolume',
            ),
          );
          final isVip = sourceIsTrue(
            await _optional(
              entry,
              toc['isVip'] ?? '',
              label: 'ruleToc.isVip',
            ),
          );
          final isPay = sourceIsTrue(
            await _optional(
              entry,
              toc['isPay'] ?? '',
              label: 'ruleToc.isPay',
            ),
          );
          var chapterUrl = catEye != null
              ? (JsonSourceRules.extract(
                      entry,
                      RuleField.extractionText(toc['chapterUrl']!) ?? '',
                    )?.toString() ??
                    '')
              : await _optional(
                  entry,
                  toc['chapterUrl']!,
                  label: 'ruleToc.chapterUrl',
                );
          if (catEye != null) {
            chapterUrl = aesBase64DecodeToString(
              chapterUrl,
              catEye.key,
              catEye.iv,
            );
          }
          final SourceChapter chapter;
          if (chapterUrl.isEmpty) {
            // The frozen's empty-URL fallbacks (`BookChapterList.kt:229-243`): a
            // volume takes the identity text `title + index`, every other chapter
            // takes the TOC page's own address, which resolves to the page it was
            // read from.
            chapter = isVolume
                ? SourceChapter.volume(
                    name,
                    index,
                    tocUrl: tocPage.url,
                    tag: tag.isEmpty ? null : tag,
                    isVip: isVip,
                    isPay: isPay,
                  )
                : SourceChapter(
                    name,
                    tocPage.url,
                    rawAddress: request.address,
                    tag: tag.isEmpty ? null : tag,
                    isVip: isVip,
                    isPay: isPay,
                  );
          } else {
            final (resolved, _) = await _request(
              tocPage.url,
              chapterUrl,
              _keyword,
            );
            chapter = SourceChapter(
              name,
              resolved,
              rawAddress: chapterUrl,
              tag: tag.isEmpty ? null : tag,
              isVolume: isVolume,
              isVip: isVip,
              isPay: isPay,
            );
          }
          // A repeated chapter address is kept, as this path always has: the frozen
          // deduplicates its list by URL (`BookChapterList.kt:123`) and the HTML
          // path refuses the repeat by name, but a JSON TOC that names one address
          // twice has always produced both chapters here. Such a pair would name one
          // row twice, which is a store-level limit (D4), not a rule decision taken
          // at this point.
          chapters.add(chapter);
        }
        // The frozen reads a page's next-URL rule only on the pages it walks
        // through; the declared-list branch parses its pages with
        // `getNextUrl = false` (`BookChapterList.kt:104-121`).
        final nextRule = readNext ? toc['nextTocUrl'] : null;
        return (
          pageUrl: tocPage.url,
          items: nextRule == null
              ? const <String>[]
              : await _pageTexts(
                  document,
                  nextRule,
                  label: 'ruleToc.nextTocUrl',
                ),
        );
      },
    );
    if (chapters.isEmpty) throw StateError('Empty table of contents');
    return (book, chapters);
  }

  /// The single book a response that is a book detail page describes, or an
  /// empty list when that page carries no name — the frozen `getInfoItem`
  /// answers null then and the search stage returns what it collected
  /// (`BookList.kt:174-179`).
  ///
  /// The frozen `getInfoItem` reads `ruleBookInfo` off the response the search
  /// stage already has, issuing no second request, and the book's URL is that
  /// response's final URL, which is what the details stage fetches afterwards.
  ///
  /// The JSON rule reader validates a whole `ruleBookInfo` group at once, so
  /// unlike the HTML branch this one requires the same declared fields the
  /// details stage requires — `tocUrl` included — and answers with the missing
  /// field's name instead of returning an empty result. A group with no `name`
  /// rule is not one it has to refuse: a source that declares none has no book
  /// to read here, where the details stage would refuse the missing field.
  Future<List<HtmlBook>> _detailPageBooks(
    Object? document,
    Uri finalUrl,
  ) async {
    final infoRules = source['ruleBookInfo'];
    final nameRule = infoRules is Map ? infoRules['name'] : null;
    if (nameRule == null || nameRule == '') {
      return const <HtmlBook>[];
    }
    final (book, _) = await _readBookInfo(
      document,
      HtmlBook(url: finalUrl, title: ''),
      _rules('ruleBookInfo', const []),
    );
    return book.title.isEmpty ? const <HtmlBook>[] : <HtmlBook>[book];
  }

  /// `ruleBookInfo` over one response document this pipeline already has.
  ///
  /// [details] decodes its own response and reads the TOC address from the page
  /// this returns; the search stage calls it for a response whose final URL
  /// matched `bookUrlPattern` (`BookList.kt:53-70`) or for the
  /// empty-element-list fallback (`BookList.kt:91`), where the frozen
  /// `getInfoItem` runs the same rules over the response it has.
  ///
  /// [hit] is the book the rules start from. A search synthesizes an empty one,
  /// so the detail page's own name and author are taken, exactly as the frozen
  /// empty `Book` takes them (`BookInfo.kt:60-73`).
  Future<(HtmlBook, Object?)> _readBookInfo(
    Object? document,
    HtmlBook hit,
    Map<String, String> info,
  ) async {
    // The frozen `ruleBookInfo.init` moves the document the remaining rules
    // read into a subtree of the response; it is a rule field too, so a `@js:`
    // or `{{...}}` in it is resolved the same way as every other value rule.
    final initRule = source['ruleBookInfo'] is Map
        ? (source['ruleBookInfo'] as Map)['init']
        : null;
    // The init rule answers the *document* the other fields read, so its own
    // extraction is read raw: a subtree stays a subtree (see `_field`'s [raw]).
    final page = initRule is String
        ? await _field(
            document,
            initRule,
            label: 'ruleBookInfo.init',
            raw: true,
          )
        : document;
    final cover = await _optional(
      page,
      info['coverUrl'] ?? '',
      label: 'ruleBookInfo.coverUrl',
    );
    final canReName = info['canReName']?.trim().isNotEmpty == true;
    final infoTitle = await _optional(
      page,
      info['name'] ?? '',
      label: 'ruleBookInfo.name',
    );
    final infoAuthor = await _optional(
      page,
      info['author'] ?? '',
      label: 'ruleBookInfo.author',
    );
    final infoLastChapter = await _optional(
      page,
      info['lastChapter'] ?? '',
      label: 'ruleBookInfo.lastChapter',
    );
    final infoWordCount = formatSourceWordCount(
      await _optional(
        page,
        info['wordCount'] ?? '',
        label: 'ruleBookInfo.wordCount',
      ),
    );
    final infoIntro = formatSourceIntro(
      await _optional(page, info['intro'] ?? '', label: 'ruleBookInfo.intro'),
    );
    final book = HtmlBook(
      url: hit.url,
      // The address text the book was opened with survives this stage, so a
      // refresh of the book this returns fetches the same address (#97).
      rawAddress: hit.rawAddress,
      // Legado only permits a detail page to replace the search title/author
      // when `canReName` is declared (BookInfo.kt:65-70).
      title: infoTitle.isNotEmpty && (canReName || hit.title.isEmpty)
          ? infoTitle
          : hit.title,
      author: infoAuthor.isNotEmpty && (canReName || hit.author.isEmpty)
          ? infoAuthor
          : hit.author,
      intro: infoIntro.isEmpty ? hit.intro : infoIntro,
      cover: cover.isEmpty ? '' : '${_url(hit.url, cover)}',
      kind: await _optional(page, info['kind'] ?? '', label: 'ruleBookInfo.kind'),
      lastChapter: infoLastChapter.isEmpty ? hit.lastChapter : infoLastChapter,
      wordCount: infoWordCount.isEmpty ? hit.wordCount : infoWordCount,
    );
    _book = book;
    return (book, page);
  }

  /// `ruleContent`: one chapter's text.
  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    if (book != null) _book = book;
    _chapter = chapter;
    _validate();
    _page = null;
    _chapterTitle = chapter.name;
    // The frozen content stage binds the next chapter's URL for its rules
    // (`AnalyzeRule.kt:761`) and stops before fetching it (`BookContent.kt:85-88`).
    _nextChapterUrl = nextChapterUrl;
    // The frozen content stage checks for a content rule first
    // (`WebBook.kt:303-306`), then answers a volume's `tag` without building a
    // request (`:307-310`); the request's headers are read after both.
    final content = _rules('ruleContent', ['content']);
    if (chapter.rendersTagAsContent) {
      return HtmlChapterBody(chapter.tag ?? '', 0);
    }
    _activeHeaders = await _ensureHeaders();
    final parts = <String>[];
    String? contentTitle;
    var firstPage = true;
    // The frozen page walk (`BookContent.kt:54-135`), the same one the HTML
    // adapter runs: this page, then the pages its `nextContentUrl` list declares.
    final pages = await walkSourcePages(
      first: (
        url: chapter.url,
        // The chapter's own address text carries its options (the frozen
        // `BookContent` fetches `chapter.url` through `AnalyzeUrl`).
        options: chapter.options,
        address: chapter.address,
        base: chapter.addressBase ?? chapter.url,
      ),
      maxPages: 20,
      cycleError: 'Content page cycle',
      // The frozen stops the one-URL walk before fetching the next chapter's
      // own URL (`BookContent.kt:85-88`); the declared-list walk has no guard.
      nextChapterUrl: nextChapterUrl == null || nextChapterUrl.isEmpty
          ? null
          : SourceHttpUri.parse(nextChapterUrl),
      resolve: (address, pageUrl) async {
        final (url, options) = await _request(pageUrl, address, _keyword);
        return (url: url, options: options);
      },
      visit: (request, {required readNext}) async {
        var contentPage = await _fetch(
          BookSourceStage.content,
          request.url,
          options: request.options,
          address: request.address,
          base: request.base,
        );
        // The frozen content stage checks login once, on its first response
        // (`WebBook.kt:336`); the `nextContentUrl` pages never run it.
        if (firstPage) {
          contentPage = await _loginCheck(contentPage);
          firstPage = false;
        }
        final document = _document(BookSourceStage.content, contentPage);
        // The frozen applies the first page's title before the content rules.
        if (parts.isEmpty) {
          final titleRule = content['title'];
          final title = titleRule == null
              ? null
              : await _optional(
                  document,
                  titleRule,
                  label: 'ruleContent.title',
                );
          if (title != null && title.trim().isNotEmpty) {
            contentTitle = _chapterTitle = title;
            _chapter = SourceChapter(
              title,
              chapter.url,
              rawAddress: chapter.rawAddress,
              storedKey: chapter.storedKey,
              addressBase: chapter.addressBase,
            );
          }
        }
        // The frozen content stage turns one page's value into text here, before
        // the pages are joined (`BookContent.kt:178`) — the same pass the HTML
        // adapter runs, because the frozen stage is adapter-agnostic.
        parts.add(
          formatChapterContent(
            await _text(
              document,
              content['content']!,
              label: 'ruleContent.content',
            ),
          ),
        );
        // The frozen reads a page's next-URL rule only on the pages it walks
        // through (`BookContent.kt:114-127`).
        final nextRule = readNext ? content['nextContentUrl'] : null;
        return (
          pageUrl: contentPage.url,
          items: nextRule == null
              ? const <String>[]
              : await _pageTexts(
                  document,
                  nextRule,
                  label: 'ruleContent.nextContentUrl',
                ),
        );
      },
    );
    // The frozen joins a chapter's pages with a newline (`BookContent.kt:129`).
    final text = parts.join('\n');
    return HtmlChapterBody(
      text,
      pages,
      title: contentTitle,
      images: extractChapterImages(text),
    );
  }

  /// One chapter image's bytes, through the same source session the JSON stages
  /// use: the source's `header` rule, the login header, the cookie jar, the
  /// per-source `concurrentRate` and the per-source TLS exception
  /// (`ImageProvider.getImageSize` → `BookHelp.saveImage` → `AnalyzeUrl(src,
  /// source = bookSource).getByteArrayAwait()`).
  ///
  /// A relative [src] resolves against the chapter's URL, which is what the
  /// frozen download path resolves one against (`BookHelp.flowImages`, `:196-205`).
  @override
  Future<Uint8List> chapterImage(String src, {Uri? base}) async {
    _cancellation.throwIfCancelled();
    final target = base == null ? SourceHttpUri.parse(src) : _url(base, src);
    final host = _host;
    if (host == null) {
      // A transport without a source session answers text, which cannot carry an
      // image back; the reader shows its own failure row rather than a
      // half-decoded one.
      throw UnsupportedError('当前 transport 不支持图片请求');
    }
    final response = await host
        .forExecution(_cancellation)
        .get('$target', headers: await _ensureHeaders(), readBytes: true);
    _cancellation.throwIfCancelled();
    final bytes = response.bodyBytes;
    if (bytes == null) throw StateError('图片响应没有字节：$target');
    return bytes;
  }

  /// The raw address texts one page's next-page rule declared, in the frozen
  /// `AnalyzeRule.getStringList` shape (`AnalyzeRule.kt:159-235`): every match of
  /// the rule, in declared order, with the field's `##` replacement applied per
  /// item and its `@js:`/`<js>` segments applied to each.
  ///
  /// A rule that is not a JSONPath is the literal template the field already
  /// interpolated, which names one page; a rule that matched nothing declares
  /// none. A script-only field runs its script on the document itself.
  ///
  /// One named limit: the frozen `getStringList` takes each matched item's own
  /// `toString()` (`AnalyzeByJSonPath.kt:83-86`), while this path reads a
  /// container item with Dart's `'$item'`, so a rule whose match is an object or
  /// array would carry `{k: v}` where the frozen side carries json-smart's
  /// `{k=v}`. No exported source reaches that shape — the rule would have to end
  /// in an index/wildcard/slice/filter, the leaf that names a container, and no
  /// used source declares either next-page field on a JSON source — so it stays
  /// an out-of-corpus limit in `tool/jsonpath_oracle/README.md` rather than being
  /// routed here under an unproven model (ticket #78).
  Future<List<String>> _pageTexts(
    Object? document,
    String rule, {
    String label = '',
  }) async {
    final field = await RuleField.resolve(
      rule,
      _ruleContext(label, document),
      content: document,
    );
    if (field.isScriptOnly) {
      return sourceScriptTexts(await field.apply(document));
    }
    final fields = splitRuleFields(field.extractionRule!);
    final extraction = fields.rule.trim();
    final lower = extraction.toLowerCase();
    final text = lower.startsWith('@json:')
        ? extraction.substring(6)
        : extraction;
    final items =
        text.isEmpty || !(text.startsWith(r'$') || text.startsWith('.'))
        ? <Object?>[JsonSourceRules.extract(document, fields.rule)]
        : JsonSourceRules.list(document, fields.rule);
    final texts = <String>[];
    for (final item in items) {
      final applied = await field.apply(applyRuleReplacement('$item', fields));
      if (applied == null) continue;
      texts.add('$applied');
    }
    return texts;
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
      _rules('ruleBookInfo', const []);
      _rules('ruleToc', ['chapterList', 'chapterName', 'chapterUrl']);
      _rules('ruleContent', ['content']);
      onStage(
        const BookSourceRunState(
          stage: BookSourceStage.search,
          message: StoreMessage(StoreMessageCode.runSearching),
        ),
      );
      final books = await search(keyword, page: page);
      if (books.isEmpty) throw StateError('No search results');
      stage = BookSourceStage.bookInfo;
      onStage(
        BookSourceRunState(
          stage: stage,
          message: StoreMessage(StoreMessageCode.runReading, <Object?>[
            books.first.title,
          ]),
        ),
      );
      final (book, chapters) = await details(books.first);
      stage = BookSourceStage.tableOfContents;
      onStage(
        const BookSourceRunState(
          stage: BookSourceStage.tableOfContents,
          message: StoreMessage(StoreMessageCode.runReadingToc),
        ),
      );
      stage = BookSourceStage.content;
      onStage(
        BookSourceRunState(
          stage: stage,
          message: StoreMessage(StoreMessageCode.runReading, <Object?>[
            chapters.first.name,
          ]),
        ),
      );
      final body = await chapter(chapters.first);
      onStage(
        const BookSourceRunState(
          stage: BookSourceStage.completed,
          message: StoreMessage(StoreMessageCode.runJsonFirstChapterDone),
        ),
      );
      return SourceReadingResult(book.title, chapters, body.text, trace);
    } catch (error) {
      onStage(
        BookSourceRunState(
          stage: BookSourceStage.failed,
          // The failure's own text is a diagnostic and stays as the code that
          // raised it wrote it; only the line's shape is the interface's (#72).
          message: StoreMessage(StoreMessageCode.runFailed, <Object?>[
            stage.name,
            '$error',
          ]),
        ),
      );
      rethrow;
    }
  }
}

/// One chapter of a source's table of contents.
///
/// [url] is the resolved request target, without any option tail. [rawAddress]
/// is the address text the TOC rule produced, options included — the frozen
/// `BookChapter.url` (`BookChapterList.kt:222`) — so the request that fetches
/// the chapter can parse its options the way the frozen `AnalyzeUrl` does
/// (`AnalyzeUrl.kt:214-222`).
///
/// [tag], [isVolume], [isVip] and [isPay] are the frozen `BookChapter` marker
/// fields: `ruleToc.updateTime`/`isVolume`/`isVip`/`isPay` read through the
/// frozen `String.isTrue()` (`BookChapterList.kt:219-253`).
class SourceChapter {
  const SourceChapter(
    this.name,
    this.url, {
    this.rawAddress,
    this.storedKey,
    this.addressBase,
    this.tag,
    this.isVolume = false,
    this.isVip = false,
    this.isPay = false,
  });

  /// A volume chapter whose URL rule produced nothing.
  ///
  /// The frozen substitutes the identity text `title + index` for the chapter's
  /// URL (`BookChapterList.kt:229-243`) and never fetches it: `getAbsoluteURL()`
  /// answers the TOC page's own URL for such a chapter
  /// (`BookChapter.kt:143-149`) and the content stage answers its `tag`
  /// (`WebBook.kt:307-310`). [tocUrl] is that TOC page URL, and the identity
  /// text is the chapter's address, which is what [storeKey] and
  /// [persistedAddress] keep.
  factory SourceChapter.volume(
    String title,
    int index, {
    required Uri tocUrl,
    String? tag,
    bool isVip = false,
    bool isPay = false,
  }) => SourceChapter(
    title,
    tocUrl,
    rawAddress: '$title$index',
    tag: tag,
    isVolume: true,
    isVip: isVip,
    isPay: isPay,
  );

  /// Rebuilds a stored address. Imported relative addresses resolve against
  /// their owning book at fetch time; the raw address remains the store's key.
  factory SourceChapter.fromAddress(
    String name,
    String address, {
    Uri? bookUrl,
    String? chapterKey,
    String? tag,
    bool isVolume = false,
    bool isVip = false,
    bool isPay = false,
  }) {
    final target = sourceUrlTargetOf(address);
    return SourceChapter(
      name,
      SourceHttpUri.parse('${bookUrl?.resolve(target) ?? target}'),
      rawAddress: address,
      storedKey: chapterKey,
      addressBase: bookUrl,
      tag: tag,
      isVolume: isVolume,
      isVip: isVip,
      isPay: isPay,
    );
  }

  final String name;
  final Uri url;

  /// The rule's own address text, or null when the caller only has a URL.
  final String? rawAddress;

  /// Existing store identity; new TOC chapters still key by their resolved URL.
  final String? storedKey;

  /// The `ruleToc.updateTime` value (the frozen `BookChapter.tag`), null when
  /// the source declares no such rule or the rule matched nothing.
  final String? tag;

  /// A volume heading rather than a readable chapter (`ruleToc.isVolume`).
  final bool isVolume;

  /// A chapter the source marks as VIP (`ruleToc.isVip`).
  final bool isVip;

  /// A chapter the source marks as already paid for (`ruleToc.isPay`).
  final bool isPay;

  /// The key a TOC write keeps for this chapter (D4). A chapter keys by its
  /// resolved target, except a volume the rules left without a URL: it has no
  /// page, so the frozen identity text is what the row keeps and what tells it
  /// apart from its siblings on the same TOC page.
  String get storeKey => rendersTagAsContent ? address : '$url';

  String get progressKey => storedKey ?? storeKey;

  /// Base used to reanalyse a stored address via `java.initUrl()`.
  final Uri? addressBase;

  /// The text a fetch parses: the rule's address when it was kept. A bare URL
  /// carries no options, so it parses to itself.
  String get address => rawAddress ?? '$url';

  /// The options this chapter's own request applies. Parsed where the chapter
  /// is fetched, not where the TOC was read, which is what keeps them across a
  /// restart once the address text is what the store holds.
  SourceUrlOptions get options => splitSourceUrlOptions(address).options;

  /// The address text to persist: the request target resolved, the option tail
  /// kept verbatim.
  ///
  /// A stored row has no TOC page left to resolve a relative address against, so
  /// the target is written absolute. The frozen stores the rule's own text and
  /// resolves it against the book's URL when it fetches the chapter; the options
  /// and the URL a request targets are the same either way, and a row written by
  /// [SourceChapter.fromAddress] keeps parsing to itself.
  ///
  /// A volume the rules left without a URL has no target to write absolute
  /// (`rendersTagAsContent`): the frozen keeps the identity text
  /// `title + index` as that chapter's whole state, so the row keeps it too and
  /// the shortcut reads it again after a restart.
  String get persistedAddress =>
      rendersTagAsContent ? address : '$url${sourceUrlOptionTailOf(address)}';

  /// The frozen `WebBook.getContentAwait` volume shortcut
  /// (`WebBook.kt:307-310`): a volume chapter whose own URL text starts with its
  /// title has no page behind it, so the chapter's `tag` is its content and
  /// nothing is fetched. The empty-URL fallback (`BookChapterList.kt:229-243`)
  /// writes exactly `title + index` into the URL, which is the shape this reads.
  bool get rendersTagAsContent => isVolume && address.startsWith(name);
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
