import 'dart:typed_data';

import '../domain/contracts.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'book_source_webview_adapter.dart';
import 'html_rule_adapter.dart';
import 'java_regex.dart';
import 'js_source_runtime.dart';
import 'rule_field.dart';
import 'source_host_dispatcher.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';
import 'source_page_results.dart';
import 'source_url_rules.dart';

class HtmlBook {
  const HtmlBook({
    required this.url,
    this.rawAddress,
    required this.title,
    this.author = '',
    this.intro = '',
    this.cover = '',
    this.kind = '',
    this.lastChapter = '',
    this.wordCount = '',
  });
  final Uri url;

  /// The address text this book was built from, option tail included, or null
  /// when the caller only has the URL.
  ///
  /// The frozen keeps a book's `bookUrl` as the rule's own string — for a
  /// shelf row, the address it was imported with — and every fetch parses the
  /// `,{…}` options out of that text (`AnalyzeUrl.kt:214-222`). A `Uri` cannot
  /// carry it: `Uri.toString()` percent-encodes a raw tail, so the split finds
  /// nothing and the encoded tail reaches the site inside the query, where its
  /// `$.data` rules match nothing (#97). This is the counterpart of
  /// [SourceChapter.rawAddress] for a book.
  final String? rawAddress;

  /// The address text a fetch parses: the one this book was built from when it
  /// was kept, and the URL text otherwise. A bare URL carries no options, so it
  /// parses to itself.
  String get address => rawAddress ?? '$url';

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
  const HtmlChapterBody(
    this.text,
    this.pages, {
    this.title,
    this.images = const [],
  });
  final String text;
  final int pages;

  /// The content-stage `ruleContent.title`, or null when the source did not
  /// declare a title rule or it returned an empty value.
  final String? title;

  /// The content images [text] carries, in document order.
  final List<SourceChapterImage> images;
}

/// One content image of a chapter body.
///
/// The frozen reader reads images out of the content string rather than through
/// a rule: the string keeps the source's own `<img …>` markup and the layout
/// finds every image with `AppPattern.imgPattern`
/// (`ChapterProvider.kt:204-236`, `TextChapterLayout.kt:229-263`), while the
/// image bytes come from that address through the source's own session
/// (`ImageProvider.getImageSize` → `BookHelp.saveImage`). This product extracts
/// the same matches once, where the chapter body is produced, and carries them
/// with that body.
///
/// [offset] and [length] are the element's own range in
/// [HtmlChapterBody.text], so an image is keyed like the text beside it: the
/// reader addresses an image by the code-unit offset its text is stored at, the
/// same space its progress record speaks.
class SourceChapterImage {
  const SourceChapterImage({
    required this.src,
    required this.offset,
    required this.length,
  });

  /// The element's own `src` attribute text, verbatim: a relative address is
  /// resolved by the loader that fetches it, exactly as the frozen download path
  /// resolves one against the chapter's URL (`BookHelp.flowImages`, `:201`).
  final String src;

  /// Where the `<img …>` element begins in [HtmlChapterBody.text].
  final int offset;

  /// The element's own length in code units — the whole tag, so a reader can
  /// drop the markup it replaced from the text it displays.
  final int length;
}

/// The frozen `AppPattern.imgPattern` (`AppPattern.kt:12`), the one pattern the
/// frozen reader's layouts and its image downloads both use:
/// `<img[^>]*src="([^"]*(?:"[^>]+\})?)"[^>]*>`.
///
/// It keeps the frozen pattern's own limits, which are recorded rather than
/// improved on: a double-quoted `src` only, a case-sensitive `<img`, and the
/// attribute before `src` matched without crossing a `>`.
final RegExp _imagePattern = RegExp(
  '<img[^>]*src="([^"]*(?:"[^>]+\\})?)"[^>]*>',
);

/// The images one chapter body carries, in document order.
List<SourceChapterImage> extractChapterImages(String text) => [
  for (final match in _imagePattern.allMatches(text))
    SourceChapterImage(
      src: match.group(1)!,
      offset: match.start,
      length: match.end - match.start,
    ),
];

/// One item an element-list rule produced, as the frozen `BookList` loop reads
/// it (`BookList.kt:101-127`): an element, or a plain value a list script built.
class _ListItem {
  const _ListItem.element(this.dom, this.rule) : value = null;
  const _ListItem.value(this.value) : dom = null, rule = null;

  /// The document the element lives in, or null for a value item.
  final String? dom;

  /// The rule that selects the element in [dom], or null for its root.
  final String? rule;

  /// The value item, or null for an element item.
  final Object? value;

  bool get isElement => dom != null;
}

/// One step of the frozen element-list walk: the raw value a segment produced,
/// or the elements an extraction segment selected (each with the rule that
/// addresses it in the step's document).
class _ListStep {
  const _ListStep.raw(this.value) : elements = null;
  const _ListStep.elements(this.elements) : value = null;

  final Object? value;
  final List<({String dom, String rule})>? elements;
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
    this.webViewFactory,
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

  /// The rendered-document adapter factory this pipeline's WebView stages use.
  /// Null builds the platform one for this source; a test substitutes its own,
  /// because the pipeline's choice of path is what it checks.
  final BookSourceWebViewAdapterFactory? webViewFactory;

  /// The source this pipeline speaks for: its `bookSourceUrl`, the key its
  /// per-source state is owned by.
  String get _sourceRef => '${source['bookSourceUrl'] ?? ''}';

  /// The source's own URL, the base a book's address text resolves against
  /// (`WebBook.kt:163`: the frozen details stage builds
  /// `AnalyzeUrl(mUrl = book.bookUrl, baseUrl = bookSource.bookSourceUrl)`).
  late final Uri _sourceBase = SourceHttpUri.parse(
    source['bookSourceUrl'] as String,
  );

  final _cancellation = SourceCancellation();

  /// The rule variables (`@get:`/`@put:`) and the script runtime read one store,
  /// the way the frozen `AnalyzeRule.get`/`put` reach the same `BaseSource`
  /// variables `java.get`/`java.put` do.
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
  late final SourceScriptRuntime _runtime =
      _scriptRuntime ??
      InProcessSourceScriptRuntime(
        dispatcher: _host,
        hostState: _hostSurface,
        jsLib: source['jsLib'] as String? ?? '',
        androidId: androidId,
        onMessage: (message) => onHostMessage?.call(message),
        ruleEvaluator: _readScriptRule,
        domEvaluator: _domOp,
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

  /// The next chapter's URL while the content stage runs — the frozen
  /// `AnalyzeRule.nextChapterUrl` (`AnalyzeRule.kt:58,761`), bound for that
  /// stage's rules and read by its own next-content guard. Null when the caller
  /// has no next chapter.
  String? _nextChapterUrl;
  HtmlBook? _book;
  SourceChapter? _chapter;

  /// The book URLs of this analysis with the address text they came from and
  /// the base that text resolved against, kept for the stage that fetches the
  /// book: the book carries its own address text ([HtmlBook.rawAddress]) but
  /// not the response URL a relative one resolved against, and `java.initUrl`
  /// re-runs the analysis of that text against that base
  /// (`SourceStageRequest.reanalyze`).
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
    // The frozen `BaseSource.getHeaderMap` answers no headers for a `header`
    // rule it cannot read (lenient Gson, and every failure caught), so a source
    // whose header text is not a JSON map runs on no source headers instead of
    // being refused. The request then carries the source's declared headers
    // only where the rule parsed — nothing else, exactly as in the frozen app.
    final headers = parseSourceHeaderMap(json);
    if (headers == null) return const {};
    if (headers.keys.any((key) => key.toLowerCase() == 'proxy')) {
      throw UnsupportedError('暂不支持代理配置');
    }
    return headers;
  }

  Map<String, Object?> _scriptInput(
    String keyword,
    Object? result, {
    Object? content,
  }) => {
    'sourceKey': _sourceRef,
    'source': _sourceFields,
    'key': keyword,
    'page': _page,
    'result': result,
    // The frozen `AnalyzeRule.evalJS` binds the analysis's own content as `src`
    // (`AnalyzeRule.kt:759`): it is the content the field being read carries, so
    // `java.getString` and its siblings read the object this field's own rule
    // read used when the source passes no content of its own.
    'src': ?content,
    'baseUrl': source['bookSourceUrl'],
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
    'headers': const <String, String>{},
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
      stage.url,
      stage.stage,
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
  /// the runtime the adapter already owns, a value rule is extracted by a
  /// one-rule Rust call ([_eagerExtract]), and `@get:`/`@put:` read and write the
  /// source-scoped variables `java.get`/`java.put` use.
  ///
  /// [label] is the rule field being read (`ruleBookInfo.kind`): a script this
  /// field runs carries it into the failure it reports, so the interface and the
  /// source log name the field instead of the bare `js`.
  ///
  /// [content] is the object the field is read against, bound as the frozen
  /// `src` for the field's scripts. This adapter reads an element field's values
  /// through one batch over the page, so a script inside an element field sees
  /// the page where the JSON adapter sees the matched element — a recorded
  /// divergence of the two-adapter split.
  RuleFieldContext _ruleContext(String label, Object? content) =>
      RuleFieldContext(
        evaluateScript: (script, result) =>
            _evalJs(script, _keyword, result, label: label, content: content),
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

  /// One node-façade read ([SourceDomRead]) over the product's own Rust HTML
  /// adapter. `count` runs the selector and answers how many elements it
  /// matched; `extract` runs the selector and answers one value per matched
  /// element — jsoup `Element.text()`, `Element.outerHtml()` (`html`), or an
  /// attribute name. The tree is parsed from [SourceDomRead.html], which is the
  /// document the node came from, so a node's own `select` scopes to its
  /// subtree exactly as jsoup's does.
  Future<Object?> _domOp(SourceDomRead read) async {
    final batch = HtmlRuleBatch(read.html);
    final selection = batch.elements('node', read.rule ?? ':root');
    if (read.op == SourceDomOp.count) {
      await batch.run();
      return selection.length;
    }
    final values = batch.elementsText('value', '@${read.extract}', selection);
    await batch.run();
    return values.values;
  }

  /// One rule field through the shared path: the `@js:`/`<js>` split and the
  /// `{{...}}`/`@get:`/`@put:` substitution happen before the stage's batch is
  /// declared, the script segments run on the extracted value afterwards.
  ///
  /// [label] is the rule field this value comes from (`ruleBookInfo.kind`); a
  /// script failure inside it reports the field's name.
  Future<RuleField> _field(
    String raw, {
    required String content,
    String label = '',
  }) async {
    return RuleField.resolve(raw, _ruleContext(label, content), content: content);
  }

  /// One `java.getString`/`getStringList`/`getElement`/`getElements` call from a
  /// rule script — the frozen `AnalyzeRule.getString` and its three siblings
  /// (`AnalyzeRule.kt:159,166,246,252,259,328,363`) — read by *this* adapter's
  /// rule path over the content object the member was given: the same
  /// [RuleField] path and Rust extraction this stage reads its own fields with,
  /// not a second engine (ADR 0012).
  ///
  /// The frozen's element forms answer the matched jsoup elements, which no
  /// boundary here carries — this adapter's engine answers text — so over HTML
  /// content they refuse by name (the JSON adapter's element forms answer the
  /// matched value) and a source reads the same text with
  /// `java.getString`/`java.getStringList`. The list form is the adapter's
  /// `AnalyzeRule.getStringList` read ([_declareList]); a rule whose script
  /// segment cannot be re-parsed as a document refuses, as this adapter's
  /// element-list fields do.
  Future<Object?> _readScriptRule(SourceRuleRead read) async {
    if (read.form == SourceRuleForm.element ||
        read.form == SourceRuleForm.elements) {
      throw SourceScriptError(
        'policy',
        '${read.member} 无法回答 HTML 内容的元素对象：本产品的 HTML 规则引擎只回答文本，'
        '请用 java.getString/java.getStringList',
      );
    }
    final field = await _field(
      read.rule,
      content: '${read.content}',
      label: read.member,
    );
    if (read.form == SourceRuleForm.stringList) {
      if (field.scripts.isNotEmpty) {
        throw SourceScriptError(
          'policy',
          '${read.member} 暂不支持带脚本的列表规则：${read.rule}',
        );
      }
      final batch = HtmlRuleBatch('${read.content}');
      final job = batch.documentTextList('rule', field.extractionRule!);
      await batch.run();
      return job.values;
    }
    final extracted = field.isScriptOnly
        ? read.content
        : await _eagerExtract(read.content, field.extractionRule!);
    return '${await field.apply(extracted) ?? ''}';
  }

  /// One per-element value rule of a stage. `{{...}}`/`@get:` substitution
  /// applies, and the rule's `@js:`/`<js>` scripts run on the value the rule
  /// produced (the extraction text when it declares one, the element the
  /// element-list rule matched when the field is script only — the frozen
  /// `AnalyzeRule.setContent(item)` binding, `BookList.kt:208`).
  Future<RuleField> _elementField(
    String raw, {
    required String content,
    String label = '',
  }) => _field(raw, content: content, label: label);

  /// One item an element-list rule produced, as the frozen `BookList` loop
  /// reads it (`BookList.kt:101-127`): an element (the document it lives in and
  /// the rule that selects it, so its own `select`/`attr`/`text` read that
  /// element) or a plain value a list script built (a string, or a JSON object).
  /// A string item is the frozen `AnalyzeRule.setContent(item)` binding for a
  /// per-element field script.
  Future<List<_ListItem>> _listItems(
    String raw,
    String body,
    String label,
  ) async {
    var step = _ListStep.raw(body);
    for (final segment in parseRuleFieldSegments(raw)) {
      if (segment.isScript) {
        // The frozen loop binds the previous segment's value as `result`
        // (`AnalyzeRule.kt:363-390`): after an extraction that value is the
        // matched element list, which the façade answers as node descriptors so
        // a script can index, iterate or stringify it.
        final elements = step.elements;
        final value = elements == null
            ? step.value
            : [
                for (final element in elements)
                  <String, Object?>{'__dom': element.dom, '__rule': element.rule},
              ];
        step = _ListStep.raw(
          await _evalJs(segment.text, _keyword, value, label: label),
        );
      } else {
        step = await _listExtract(step, segment.text, label);
      }
    }
    return _itemsOfStep(step);
  }

  /// One extraction segment of a scripted element-list rule: the frozen
  /// `getAnalyzeByJSoup(result).getElements(rule)` parses the current value as a
  /// document and selects from it. The value may be the response body string, a
  /// string a script produced, or a node the façade answered.
  Future<_ListStep> _listExtract(
    _ListStep step,
    String rule,
    String label,
  ) async {
    if (step.elements != null) {
      throw UnsupportedError('$label 的提取片段不能跟在另一个提取片段之后：$rule');
    }
    final String dom;
    final String combined;
    final value = step.value;
    if (value is Map) {
      final source = value['__dom'];
      if (source is! String) {
        throw UnsupportedError('$label 的脚本结果不是可提取的文档：$rule');
      }
      dom = source;
      final base = value['__rule'];
      combined = base is String ? '$base@$rule' : rule;
    } else if (value is String) {
      dom = value;
      combined = rule;
    } else {
      throw UnsupportedError('$label 的脚本结果不是文本或元素，无法继续提取：$rule');
    }
    final batch = HtmlRuleBatch(dom);
    final selection = batch.elements('items', combined);
    await batch.run();
    return _ListStep.elements([
      for (var index = 0; index < selection.length; index++)
        (dom: dom, rule: '$combined.$index'),
    ]);
  }

  /// The items one scripted element-list rule's final value carries: an element
  /// selection, a string list the frozen `AnalyzeRule.getStringList` splits on
  /// newlines, or a script's own array (element descriptors, strings, objects).
  List<_ListItem> _itemsOfStep(_ListStep step) {
    final elements = step.elements;
    if (elements != null) {
      return [for (final element in elements) _ListItem.element(element.dom, element.rule)];
    }
    final value = step.value;
    if (value == null) return const <_ListItem>[];
    if (value is String) {
      return [
        for (final line in value.split('\n'))
          if (line.isNotEmpty) _ListItem.value(line),
      ];
    }
    if (value is List) return [for (final item in value) _listItemOf(item)];
    return <_ListItem>[_listItemOf(value)];
  }

  _ListItem _listItemOf(Object? value) {
    if (value is Map && value['__dom'] is String) {
      final rule = value['__rule'];
      return _ListItem.element(
        value['__dom'] as String,
        rule is String ? rule : null,
      );
    }
    return _ListItem.value(value);
  }

  /// One element-list field's values, over either the page batch or the items a
  /// scripted list rule produced. A script-only field runs its script against
  /// the item itself (an element node, or a plain value); an extraction field
  /// keeps the batch read.
  Future<List<String>> _listFieldValues({
    required RuleField field,
    required List<_ListItem>? scriptedItems,
    required HtmlStringList? job,
    required List<String> itemHtmls,
    String label = '',
    bool url = false,
  }) async {
    if (scriptedItems != null) {
      return [
        for (final item in scriptedItems)
          await _itemFieldValue(item, field, label, url: url),
      ];
    }
    if (field.isScriptOnly) {
      return [
        for (final html in itemHtmls)
          await _itemFieldValue(
            _ListItem.element(html, 'body > :first-child'),
            field,
            label,
            url: url,
          ),
      ];
    }
    return _perElement(field, job!.values, url: url);
  }

  Future<String> _itemFieldValue(
    _ListItem item,
    RuleField field,
    String label, {
    bool url = false,
  }) async {
    if (item.isElement) {
      final dom = item.dom!;
      final rule = item.rule ?? ':root';
      if (field.isScriptOnly) {
        final value = await field.apply(<String, Object?>{
          '__dom': dom,
          '__rule': rule,
        });
        return '${value ?? ''}';
      }
      final batch = HtmlRuleBatch(dom);
      final selection = batch.elements('item', rule);
      final values = batch.elementsText(
        'value',
        field.extractionRule!,
        selection,
      );
      await batch.run();
      final extracted = values.values.isEmpty ? '' : values.values.first;
      return '${await field.apply(_urlFallback(field, extracted, url)) ?? ''}';
    }
    if (field.isScriptOnly) {
      return '${await field.apply(item.value) ?? ''}';
    }
    // The frozen `AnalyzeByJSoup(result)` parses a non-element item's text as a
    // document before its rule runs.
    final batch = HtmlRuleBatch('${item.value ?? ''}');
    final value = batch.documentText('value', field.extractionRule!);
    await batch.run();
    return '${await field.apply(_urlFallback(field, value.value, url)) ?? ''}';
  }

  /// The URL mode's replacement when the extraction found nothing, as
  /// [_perElement] applies it.
  String _urlFallback(RuleField field, String value, bool url) =>
      url && value.isEmpty && !field.isScriptOnly
      ? applyRuleReplacement(
          '',
          splitRuleFields(field.extractionRule!),
          label: 'HTML',
        )
      : value;

  /// Declares the document job of one field, or none when the field is a script
  /// only.
  HtmlString? _declare(HtmlRuleBatch batch, String id, RuleField field) =>
      field.isScriptOnly ? null : batch.documentText(id, field.extractionRule!);

  /// Declares the *list* read of one field (the frozen
  /// `AnalyzeRule.getStringList`), or none when the field is a script only. The
  /// frozen reads a page's next-page rule only as a list, so a `##` field on it
  /// runs per declared item and its values reach the walk as the extraction left
  /// them; a single-value field keeps [_declare].
  HtmlStringList? _declareList(
    HtmlRuleBatch batch,
    String id,
    RuleField field,
  ) => field.isScriptOnly
      ? null
      : batch.documentTextList(id, field.extractionRule!);

  /// Reads one declared document job with the field's scripts applied. A
  /// script-only field is applied to the page's HTML text, where the frozen
  /// reader passes the parsed tree a JavaScript boundary cannot carry — a
  /// recorded divergence.
  Future<String> _documentValue(
    HtmlString? job,
    RuleField field,
    String content, {
    bool url = false,
  }) async {
    final value = field.isScriptOnly ? content : job!.value;
    final resolved = url && value.isEmpty && !field.isScriptOnly
        ? applyRuleReplacement(
            '',
            splitRuleFields(field.extractionRule!),
            label: 'HTML',
          )
        : value;
    return '${await field.apply(resolved) ?? ''}';
  }

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
    List<String> values, {
    bool url = false,
  }) async => [
    for (final value in values)
      '${await field.apply(url && value.isEmpty ? applyRuleReplacement('', splitRuleFields(field.extractionRule!), label: 'HTML') : value) ?? ''}',
  ];

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
    // The frozen replaces the URL with the option script's result only when that
    // result is not null (`AnalyzeUrl.kt:238-242`). A script that only shows a
    // notice answers nothing, so the address the rule wrote stands; stringifying
    // that nothing into `'null'` sent the request to `/null` (#94).
    final text = script == null
        ? split.path
        : (await _evalJs(
                script,
                keyword,
                '${_resolve(base, split.path, keepFragment: true)}',
              ))
              ?.toString() ??
              split.path;
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

  /// Sends one stage request and answers the stage response as the rules and
  /// the stage's `loginCheckJs` read it.
  ///
  /// [address] is the address text this request came from and [base] the URL it
  /// resolved against; both are kept for `java.initUrl`, which re-runs the
  /// address analysis (`SourceStageRequest.reanalyze`). A caller that only has
  /// the resolved URL passes neither: the URL text is then the address.
  Future<SourceStageResponse> _fetch(
    Uri url,
    BookSourceStage stage, {
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
    final sourceHeaders = await _headers();
    final merged = {...sourceHeaders, ...options.headers};
    final (method: method, body: body, headers: extra) =
        await sourceRequestShape(options, merged);
    final headers = {...merged, ...extra};
    final host = _host;
    if (options.webView) {
      // The frozen `AnalyzeUrl` WebView path, under this source's rate limit:
      // `withLimit` encloses the whole operation, bootstrap and load alike.
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
      _cancellation.throwIfCancelled();
      trace.add(BookSourceTraceEntry(stage: stage, path: '$url'));
      // A rendered document has no HTTP response of its own: the frozen
      // `StrResponse(url, body)` reports status 200 and no headers.
      return SourceStageResponse.webView(body: result.body, url: result.url);
    }
    final String text;
    var finalUrl = url;
    var statusCode = 200;
    var responseHeaders = const <String, List<String>>{};
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
      statusCode = response.statusCode;
      responseHeaders = response.headers;
    } else {
      if (method != 'GET' || headers.isNotEmpty) {
        throw UnsupportedError('当前 transport 不支持 HTTP 请求选项');
      }
      text = await transport.request(stage: stage, path: '$url');
    }
    _cancellation.throwIfCancelled();
    trace.add(BookSourceTraceEntry(stage: stage, path: '$url'));
    return SourceStageResponse(
      body: text,
      url: finalUrl,
      statusCode: statusCode,
      headers: responseHeaders,
    );
  }

  @override
  Future<List<HtmlBook>> search(String keyword, {int page = 1}) async {
    _book = null;
    _chapter = null;
    _chapterTitle = null;
    _cancellation.throwIfCancelled();
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
    // The check sees the stage's own response and may replace it, so the rules
    // below read what it returned (`WebBook.kt:71`).
    final checked = await _loginCheck(
      await _fetch(
        url,
        BookSourceStage.search,
        options: options,
        address: source['searchUrl'] as String,
        base: base,
      ),
    );
    final html = checked.body;
    final finalUrl = checked.url;
    final bookUrlPattern = '${source['bookUrlPattern'] ?? ''}';
    // The frozen search stage asks first whether the response is a book detail
    // page, and returns that one book when it is; the element-list rules below
    // are never read (`BookList.kt:53-70`).
    if (bookUrlPattern.isNotEmpty &&
        javaMatchesWhole(
          bookUrlPattern,
          '$finalUrl',
          label: 'bookUrlPattern',
        )) {
      return _detailPageBooks(finalUrl, html);
    }
    final rawList = _rule('ruleSearch', 'bookList');
    final listRule = await _field(
      rawList,
      content: html,
      label: 'ruleSearch.bookList',
    );
    // A scripted element-list rule reads its own item list (the frozen
    // `AnalyzeRule.getElements`); the extraction-only shape keeps the one
    // batch over the page.
    final scriptedItems = listRule.scripts.isEmpty
        ? null
        : await _listItems(rawList, html, 'ruleSearch.bookList');
    final batch = HtmlRuleBatch(scriptedItems == null ? html : '');
    final items = scriptedItems == null
        ? batch.elements('items', listRule.extractionRule!)
        : null;
    final name = await _elementField(
      _rule('ruleSearch', 'name'),
      content: html,
      label: 'ruleSearch.name',
    );
    final bookUrl = await _elementField(
      _rule('ruleSearch', 'bookUrl'),
      content: html,
      label: 'ruleSearch.bookUrl',
    );
    final author = await _elementField(
      _rule('ruleSearch', 'author', optional: true),
      content: html,
      label: 'ruleSearch.author',
    );
    final intro = await _elementField(
      _rule('ruleSearch', 'intro', optional: true),
      content: html,
      label: 'ruleSearch.intro',
    );
    final lastChapter = await _elementField(
      _rule('ruleSearch', 'lastChapter', optional: true),
      content: html,
      label: 'ruleSearch.lastChapter',
    );
    final wordCount = await _elementField(
      _rule('ruleSearch', 'wordCount', optional: true),
      content: html,
      label: 'ruleSearch.wordCount',
    );
    final kind = await _elementField(
      _rule('ruleSearch', 'kind', optional: true),
      content: html,
      label: 'ruleSearch.kind',
    );
    final searchFields = <String, RuleField>{
      'name': name,
      'bookUrl': bookUrl,
      'author': author,
      'intro': intro,
      'lastChapter': lastChapter,
      'wordCount': wordCount,
      'kind': kind,
    };
    final jobs = <String, HtmlStringList?>{
      for (final entry in searchFields.entries)
        entry.key: (scriptedItems == null && !entry.value.isScriptOnly)
            ? batch.elementsText(
                entry.key,
                entry.value.extractionRule!,
                items!,
              )
            : null,
    };
    // A script-only per-element field needs each item's own element
    // (`BookList.kt:208` `setContent(item)`): its outer html is the node a
    // script's `result` answers.
    final itemHtmls = scriptedItems == null &&
            searchFields.values.any((field) => field.isScriptOnly)
        ? batch.elementsText('item-html', '@html', items!)
        : null;
    await batch.run();
    final count = scriptedItems?.length ?? items!.length;
    // The frozen companion to the branch above: an empty element list and no
    // `bookUrlPattern` mean the page is a detail page too (`BookList.kt:88-99`).
    if (count == 0 && bookUrlPattern.isEmpty) {
      return _detailPageBooks(finalUrl, html);
    }

    Future<List<String>> fieldValues(String key, {bool url = false}) =>
        _listFieldValues(
          field: searchFields[key]!,
          scriptedItems: scriptedItems,
          job: jobs[key],
          itemHtmls: itemHtmls?.values ?? const <String>[],
          label: 'ruleSearch.$key',
          url: url,
        );
    final titles = await fieldValues('name');
    final links = await fieldValues('bookUrl', url: true);
    final authorValues = await fieldValues('author');
    final introValues = await fieldValues('intro');
    final lastChapterValues = await fieldValues('lastChapter');
    final wordCountValues = await fieldValues('wordCount');
    final kindValues = await fieldValues('kind');

    final books = <HtmlBook>[];
    for (var index = 0; index < count; index++) {
      // The address text the rule produced, option tail included: it is what
      // this book keeps ([HtmlBook.rawAddress]) and what the details request
      // parses, exactly as the frozen stores `book.bookUrl` (#97).
      final bookAddress = _required(links, index, 'ruleSearch.bookUrl');
      final (bookUrlTarget, bookOptions) = await _extracted(
        finalUrl,
        bookAddress,
      );
      _bookRequests[bookUrlTarget] = (
        address: bookAddress,
        base: finalUrl,
        options: bookOptions,
      );
      books.add(
        HtmlBook(
          url: bookUrlTarget,
          rawAddress: bookAddress,
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
        ? await _request(_sourceBase, hit.address, '')
        : (hit.url, bookRequest.options);
    final bookInfo = await _loginCheck(
      await _fetch(
        bookUrl,
        BookSourceStage.bookInfo,
        options: bookOptions,
        address: bookRequest?.address ?? hit.address,
        base: bookRequest?.base ?? _sourceBase,
      ),
    );
    final html = bookInfo.body;
    final infoUrl = bookInfo.url;
    final (book, tocText) = await _readBookInfo(
      html,
      infoUrl,
      hit,
      withTocUrl: true,
    );
    // The frozen falls back to the book's own address when the detail page
    // declares no TOC address — `BookInfo.kt:150-152` reads `infoRule.tocUrl`,
    // then `if (book.tocUrl.isEmpty()) book.tocUrl = baseUrl`, where `baseUrl`
    // is the book's URL, option tail and all (`WebBook.kt` passes
    // `book.bookUrl`). The detail page is usually the TOC page, so an empty
    // rule means "this page": the request the details stage just made, whose
    // options the TOC fetch parses again.
    final (tocTarget, tocOptions) = tocText.isEmpty
        ? (bookUrl, bookOptions)
        : await _extracted(infoUrl, tocText);
    final chapterKeys = <String>{};
    final chapters = <SourceChapter>[];
    tocPages = 0;
    var firstPage = true;
    // The frozen page walk (`BookChapterList.kt:48-121`): this page, then the
    // pages its `nextTocUrl` list declares, one at a time and in declared order.
    await walkSourcePages(
      first: (
        url: tocTarget,
        options: tocOptions,
        address: tocText,
        base: infoUrl,
      ),
      maxPages: 30,
      cycleError: '目录分页循环或超出 30 页',
      // The frozen drops an item equal to the page it was read from
      // (`BookChapterList.kt:96-100`).
      dropSelf: true,
      resolve: (address, pageUrl) async {
        final (url, options) = await _extracted(pageUrl, address);
        return (url: url, options: options);
      },
      visit: (request, {required readNext}) async {
        var fetched = await _fetch(
          request.url,
          BookSourceStage.tableOfContents,
          options: request.options,
          address: request.address,
          base: request.base,
        );
        // The frozen TOC stage checks login once, on its first response
        // (`WebBook.kt:253`); the `nextTocUrl` pages `BookChapterList` fetches
        // afterwards never run the check.
        if (firstPage) {
          fetched = await _loginCheck(fetched);
          firstPage = false;
        }
        final page = fetched.body;
        final pageUrl = fetched.url;
        tocPages++;
        final rawList = _rule('ruleToc', 'chapterList');
        final listRule = await _field(
          rawList,
          content: page,
          label: 'ruleToc.chapterList',
        );
        final scriptedItems = listRule.scripts.isEmpty
            ? null
            : await _listItems(rawList, page, 'ruleToc.chapterList');
        final batch = HtmlRuleBatch(scriptedItems == null ? page : '');
        final items = scriptedItems == null
            ? batch.elements('items', listRule.extractionRule!)
            : null;
        final nameField = await _elementField(
          _rule('ruleToc', 'chapterName'),
          content: page,
          label: 'ruleToc.chapterName',
        );
        // A blank `chapterUrl` is not a refusal: the frozen reads an empty rule
        // list as `""` and then takes the empty-URL fallback
        // (`BookChapterList.kt:229-243`), which this builder already applies
        // below, so the field is optional here.
        final urlField = await _elementField(
          _rule('ruleToc', 'chapterUrl', optional: true),
          content: page,
          label: 'ruleToc.chapterUrl',
        );
        final tagField = await _elementField(
          _rule('ruleToc', 'updateTime', optional: true),
          content: page,
          label: 'ruleToc.updateTime',
        );
        final volumeField = await _elementField(
          _rule('ruleToc', 'isVolume', optional: true),
          content: page,
          label: 'ruleToc.isVolume',
        );
        final vipField = await _elementField(
          _rule('ruleToc', 'isVip', optional: true),
          content: page,
          label: 'ruleToc.isVip',
        );
        final payField = await _elementField(
          _rule('ruleToc', 'isPay', optional: true),
          content: page,
          label: 'ruleToc.isPay',
        );
        final tocFields = <String, RuleField>{
          'chapterName': nameField,
          'chapterUrl': urlField,
          'updateTime': tagField,
          'isVolume': volumeField,
          'isVip': vipField,
          'isPay': payField,
        };
        final jobs = <String, HtmlStringList?>{
          for (final entry in tocFields.entries)
            entry.key: (scriptedItems == null && !entry.value.isScriptOnly)
                ? batch.elementsText(
                    entry.key,
                    entry.value.extractionRule!,
                    items!,
                  )
                : null,
        };
        final itemHtmls = scriptedItems == null &&
                tocFields.values.any((field) => field.isScriptOnly)
            ? batch.elementsText('item-html', '@html', items!)
            : null;
        // The frozen reads a page's next-URL rule only on the pages it walks
        // through; the declared-list branch parses its pages with
        // `getNextUrl = false` (`BookChapterList.kt:104-121`).
        final next = readNext
            ? await _field(
                _rule('ruleToc', 'nextTocUrl', optional: true),
                content: page,
                label: 'ruleToc.nextTocUrl',
              )
            : null;
        final nextValue = next == null
            ? null
            : _declareList(batch, 'next', next);
        await batch.run();
        final count = scriptedItems?.length ?? items!.length;
        if (count == 0) throw StateError('目录页为空');
        Future<List<String>> fieldValues(String key, {bool url = false}) =>
            _listFieldValues(
              field: tocFields[key]!,
              scriptedItems: scriptedItems,
              job: jobs[key],
              itemHtmls: itemHtmls?.values ?? const <String>[],
              label: 'ruleToc.$key',
              url: url,
            );
        final names2 = await fieldValues('chapterName');
        final urls2 = await fieldValues('chapterUrl', url: true);
        final tagValues = await fieldValues('updateTime');
        final volumeValues = await fieldValues('isVolume');
        final vipValues = await fieldValues('isVip');
        final payValues = await fieldValues('isPay');
        for (var index = 0; index < count; index++) {
          // The frozen adds a chapter only when its title is non-empty
          // (`BookChapterList.kt:244`), so an element the name rule matched
          // nothing on is skipped instead of failing the whole TOC.
          final title = names2[index];
          if (title.isEmpty) continue;
          final tag = tagValues[index].isEmpty ? null : tagValues[index];
          final isVolume = sourceIsTrue(volumeValues[index]);
          final isVip = sourceIsTrue(vipValues[index]);
          final isPay = sourceIsTrue(payValues[index]);
          final SourceChapter chapter;
          if (urls2[index].isEmpty) {
            // The frozen's empty-URL fallbacks (`BookChapterList.kt:229-243`): a
            // volume takes the identity text `title + index`, every other chapter
            // takes the address of the TOC page being parsed, which resolves to
            // that same page (`BookChapter.kt:143-149`).
            chapter = isVolume
                ? SourceChapter.volume(
                    title,
                    index,
                    tocUrl: pageUrl,
                    tag: tag,
                    isVip: isVip,
                    isPay: isPay,
                  )
                : SourceChapter(
                    title,
                    pageUrl,
                    rawAddress: request.address,
                    tag: tag,
                    isVip: isVip,
                    isPay: isPay,
                  );
          } else {
            // The address text the rule produced, option tail included: this is
            // what the chapter keeps, so the fetch parses the options the frozen
            // `AnalyzeUrl` parses (`AnalyzeUrl.kt:214-222`).
            final rawAddress = urls2[index];
            final (chapterUrl, chapterOptions) = await _extracted(
              pageUrl,
              rawAddress,
            );
            // The address text's options are the chapter's own: the frozen
            // `AnalyzeUrl` parses them when the chapter is fetched, and this
            // adapter keeps them in the raw address (`SourceChapter.options`,
            // `persistedAddress`) so a restart keeps them (#58). Per-chapter
            // headers and the retry count are applied by the content request
            // itself; a POST body and a post-resolution `js` are the two
            // families the content stage does not express yet, so they keep
            // their named refusal (#58's test pins the body case). Headers used
            // to be refused here with them, which refused a whole TOC for a tail
            // the transport sends happily — the operator's real source run hit
            // it (零点看书's `ruleToc.chapterUrl`, batch 17).
            if (chapterOptions.isPost ||
                chapterOptions.body != null ||
                chapterOptions.js != null) {
              throw UnsupportedError('暂不支持章节地址的 URL 选项');
            }
            chapter = SourceChapter(
              title,
              chapterUrl,
              rawAddress: rawAddress,
              tag: tag,
              isVolume: isVolume,
              isVip: isVip,
              isPay: isPay,
            );
          }
          // The frozen deduplicates its list by chapter URL
          // (`BookChapterList.kt:123`); a duplicate key cannot be stored (D4), so
          // it is refused here by name.
          if (!chapterKeys.add(chapter.storeKey)) {
            throw StateError('目录含重复章节：${chapter.storeKey}');
          }
          chapters.add(chapter);
        }
        return (
          pageUrl: pageUrl,
          items: await _pageTexts(nextValue, next, page),
        );
      },
    );
    if (chapters.isEmpty) throw StateError('目录为空');
    return (book, chapters);
  }

  /// The single book a response that is a book detail page describes, or an
  /// empty list when that page carries no name — the frozen `getInfoItem`
  /// answers null then and the search stage returns what it collected
  /// (`BookList.kt:174-179`).
  ///
  /// A source that declares no `ruleBookInfo.name` has no book to read here
  /// either, where the details stage would refuse the missing field by name.
  ///
  /// The book's URL is the response's final URL: the frozen `getInfoItem`
  /// keeps `baseUrl` for a redirected response and the request's own address
  /// text otherwise (`BookList.kt:159-163`), and both are the URL this response
  /// was produced for, which is what the details stage fetches afterwards.
  Future<List<HtmlBook>> _detailPageBooks(Uri finalUrl, String html) async {
    if (_rule('ruleBookInfo', 'name', optional: true).isEmpty) {
      return const <HtmlBook>[];
    }
    final (book, _) = await _readBookInfo(
      html,
      finalUrl,
      HtmlBook(url: finalUrl, title: ''),
      withTocUrl: false,
    );
    return book.title.isEmpty ? const <HtmlBook>[] : <HtmlBook>[book];
  }

  /// The `ruleBookInfo` rules over a response this pipeline already has.
  ///
  /// [details] fetches its own response and reads the TOC address from it; the
  /// search stage calls this for a response whose final URL matched
  /// `bookUrlPattern` (`BookList.kt:53-70`) or for the empty-element-list
  /// fallback (`BookList.kt:91`), where the frozen `getInfoItem` runs the same
  /// rules over the response it has and reads no TOC address — [withTocUrl] is
  /// false there and the text it returns is empty.
  ///
  /// [hit] is the book the rules start from. A search synthesizes an empty one,
  /// so the detail page's own name and author are taken, exactly as the frozen
  /// empty `Book` takes them (`BookInfo.kt:60-73`).
  Future<(HtmlBook, String)> _readBookInfo(
    String html,
    Uri infoUrl,
    HtmlBook hit, {
    required bool withTocUrl,
  }) async {
    final batch = HtmlRuleBatch(html);
    // An absent or empty `ruleBookInfo.name` is not an error in the frozen app:
    // `analyzeRule.getString(infoRule.name)` answers "" and the book keeps the
    // name it already had (`BookInfo.kt:64-70`: `if (it.isNotEmpty() && …)`),
    // which is the search hit's title. Reading it as required refused a source
    // whose detail page carries no name at all (found by the operator's real
    // source run, batch 17).
    final name = await _field(
      _rule('ruleBookInfo', 'name', optional: true),
      content: html,
      label: 'ruleBookInfo.name',
    );
    final nameValue = _declare(batch, 'name', name);
    final author = await _field(
      _rule('ruleBookInfo', 'author', optional: true),
      content: html,
      label: 'ruleBookInfo.author',
    );
    final authorValue = _declare(batch, 'author', author);
    final intro = await _field(
      _rule('ruleBookInfo', 'intro', optional: true),
      content: html,
      label: 'ruleBookInfo.intro',
    );
    final introValue = _declare(batch, 'intro', intro);
    final cover = await _field(
      _rule('ruleBookInfo', 'coverUrl', optional: true),
      content: html,
      label: 'ruleBookInfo.coverUrl',
    );
    final coverValue = _declare(batch, 'cover', cover);
    final kind = await _field(
      _rule('ruleBookInfo', 'kind', optional: true),
      content: html,
      label: 'ruleBookInfo.kind',
    );
    final kindValue = _declare(batch, 'kind', kind);
    final lastChapter = await _field(
      _rule('ruleBookInfo', 'lastChapter', optional: true),
      content: html,
      label: 'ruleBookInfo.lastChapter',
    );
    final lastChapterValue = _declare(batch, 'lastChapter', lastChapter);
    final wordCount = await _field(
      _rule('ruleBookInfo', 'wordCount', optional: true),
      content: html,
      label: 'ruleBookInfo.wordCount',
    );
    final wordCountValue = _declare(batch, 'wordCount', wordCount);
    final canReName = _rule(
      'ruleBookInfo',
      'canReName',
      optional: true,
    ).trim().isNotEmpty;
    final tocUrl = withTocUrl
        ? await _field(
            _rule('ruleBookInfo', 'tocUrl', optional: true),
            content: html,
            label: 'ruleBookInfo.tocUrl',
          )
        : null;
    final tocValue = tocUrl == null ? null : _declare(batch, 'tocUrl', tocUrl);
    await batch.run();

    final coverText = await _documentValue(coverValue, cover, html, url: true);
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
      // The address text the book was opened with survives this stage, so a
      // refresh of the book this returns fetches the same address (#97).
      rawAddress: hit.rawAddress,
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
    final tocText = tocUrl == null
        ? ''
        : await _documentValue(tocValue, tocUrl, html, url: true);
    return (book, tocText);
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
    String? nextChapterUrl,
  }) async {
    if (book != null) _book = book;
    _chapter = chapter;
    _page = null;
    _chapterTitle = chapter.name;
    // The frozen content stage binds the next chapter's URL for its rules
    // (`AnalyzeRule.kt:761`) and stops before fetching it (`BookContent.kt:85-88`).
    _nextChapterUrl = nextChapterUrl;
    // The frozen content stage reads the content rule before the volume
    // shortcut (`WebBook.kt:303-306`), so a source that declares none keeps
    // failing by name; the shortcut (`:307-310`) then answers the chapter's
    // `tag` without building a request or reading the source headers.
    _rule('ruleContent', 'content');
    if (chapter.rendersTagAsContent) {
      return HtmlChapterBody(chapter.tag ?? '', 0);
    }
    final parts = <String>[];
    String? contentTitle;
    var firstPage = true;
    // The chapter's own address text carries the options its first request
    // applies (the frozen `BookContent` fetches `chapter.url` through
    // `AnalyzeUrl`, so a chapter address that asked for the WebView is
    // rendered), and reanalysis of a stored relative address uses the book URL
    // that first resolved it.
    final pages = await walkSourcePages(
      first: (
        url: chapter.url,
        options: chapter.options,
        address: chapter.address,
        base: chapter.addressBase ?? chapter.url,
      ),
      maxPages: 20,
      cycleError: '正文分页循环或超出 20 页',
      // The frozen stops the one-URL walk before fetching the next chapter's
      // own URL (`BookContent.kt:85-88`); the declared-list walk has no guard.
      nextChapterUrl: nextChapterUrl == null || nextChapterUrl.isEmpty
          ? null
          : SourceHttpUri.parse(nextChapterUrl),
      resolve: (address, pageUrl) async {
        // The next page's own address text carries its options, as it does for
        // every other page of a content request.
        final (url, options) = await _extracted(pageUrl, address);
        if (options.isPost ||
            options.body != null ||
            options.headers.isNotEmpty ||
            options.js != null) {
          throw UnsupportedError('暂不支持正文分页地址的 URL 选项');
        }
        return (url: url, options: options);
      },
      visit: (request, {required readNext}) async {
        var fetched = await _fetch(
          request.url,
          BookSourceStage.content,
          options: request.options,
          address: request.address,
          base: request.base,
        );
        // The frozen content stage checks login once, on its first response
        // (`WebBook.kt:336`); the `nextContentUrl` pages never run it.
        if (firstPage) {
          fetched = await _loginCheck(fetched);
          firstPage = false;
        }
        final html = fetched.body;
        final pageUrl = fetched.url;
        // Frozen BookContent applies the first-page title before parsing content
        // rules: their scripts and {{chapter.title}} see the updated value.
        if (parts.isEmpty) {
          final titleRule = _rule('ruleContent', 'title', optional: true);
          if (titleRule.trim().isNotEmpty) {
            final title = await _field(
              titleRule,
              content: html,
              label: 'ruleContent.title',
            );
            final titleBatch = HtmlRuleBatch(html);
            final titleValue = _declare(titleBatch, 'title', title);
            await titleBatch.run();
            final extracted = await _documentValue(titleValue, title, html);
            if (extracted.trim().isNotEmpty) {
              contentTitle = _chapterTitle = extracted;
              _chapter = SourceChapter(
                extracted,
                chapter.url,
                rawAddress: chapter.rawAddress,
                storedKey: chapter.storedKey,
                addressBase: chapter.addressBase,
              );
            }
          }
        }
        final content = await _field(
          _contentRule(
            SourceChapter(
              _chapterTitle!,
              chapter.url,
              rawAddress: chapter.rawAddress,
              storedKey: chapter.storedKey,
              addressBase: chapter.addressBase,
            ),
          ),
          content: html,
          label: 'ruleContent.content',
        );
        final next = readNext
            ? await _field(
                _rule('ruleContent', 'nextContentUrl', optional: true),
                content: html,
                label: 'ruleContent.nextContentUrl',
              )
            : null;
        final batch = HtmlRuleBatch(html);
        final contentValue = _declare(batch, 'content', content);
        final nextValue = next == null
            ? null
            : _declareList(batch, 'next', next);
        await batch.run();
        final text = await _documentValue(contentValue, content, html);
        if (text.isEmpty) {
          throw const FormatException('ruleContent.content 未匹配到内容');
        }
        parts.add(text);
        return (
          pageUrl: pageUrl,
          items: await _pageTexts(nextValue, next, html),
        );
      },
    );
    final text = _shapeJoinedContent(parts.join('\n'));
    return HtmlChapterBody(
      text,
      pages,
      title: contentTitle,
      images: extractChapterImages(text),
    );
  }

  /// One chapter image's bytes, through this source's own session.
  ///
  /// The frozen reader fetches a content image like any other source address —
  /// `ImageProvider.cacheImage` → `BookHelp.saveImage` →
  /// `AnalyzeUrl(src, source = bookSource).getByteArrayAwait()`
  /// (`ImageProvider.kt:110-150`, `BookHelp.kt:219-262`, `AnalyzeUrl.kt:528-549`)
  /// — so the source's `header` rule, its login header, its cookie jar, its
  /// per-source `concurrentRate` and its per-source TLS exception all apply.
  /// Every request of this source already goes through [SourceHostDispatcher],
  /// and so does this one; there is no bare `HttpClient` for an image.
  ///
  /// A relative [src] resolves against the chapter's URL, which is what the
  /// frozen download path resolves one against (`BookHelp.flowImages`, `:196-205`);
  /// the frozen layout path hands its raw text to `AnalyzeUrl` with no base at
  /// all.
  @override
  Future<Uint8List> chapterImage(String src, {Uri? base}) async {
    _cancellation.throwIfCancelled();
    final target = base == null
        ? SourceHttpUri.parse(src)
        : _resolve(base, src);
    final host = _host;
    if (host == null) {
      // A transport without a source session answers text, which cannot carry an
      // image back; the reader shows its own failure row rather than a
      // half-decoded one.
      throw UnsupportedError('当前 transport 不支持图片请求');
    }
    final response = await host
        .forExecution(_cancellation)
        .get('$target', headers: await _headers(), readBytes: true);
    _cancellation.throwIfCancelled();
    final bytes = response.bodyBytes;
    if (bytes == null) throw StateError('图片响应没有字节：$target');
    return bytes;
  }

  /// The raw address texts one page's next-page rule declared, in the frozen
  /// `AnalyzeRule.getStringList` shape (`AnalyzeRule.kt:159-235`): every match of
  /// the rule, in declared order, with the field's `@js:`/`<js>` segments
  /// applied. The values are the bridge's own list read, so a `##` field ran on
  /// each value and no entity unescape happened.
  ///
  /// A rule that matched nothing declares no page, and unlike the single-value
  /// read ([_documentValue]) the list read has no `##`-replacement fallback: the
  /// frozen's `getStringList` answers an empty list there. A script-only field
  /// runs its script on the page itself; a field with scripts runs them per
  /// declared item, where the frozen threads the whole list through the trailing
  /// segment.
  ///
  /// [job] is the declared document job and [field] the resolved field; [field]
  /// is null when the page must not read its list at all (a page the declared
  /// walk fetched, `BookChapterList.kt:104-121`).
  Future<List<String>> _pageTexts(
    HtmlStringList? job,
    RuleField? field,
    String page,
  ) async {
    if (field == null) return const <String>[];
    if (job == null) return sourceScriptTexts(await field.apply(page));
    final values = job.values;
    if (values.isEmpty && field.scripts.isEmpty) return const <String>[];
    final texts = <String>[];
    for (final value in values.isEmpty ? const <String>[''] : values) {
      final applied = await field.apply(value);
      if (applied == null) continue;
      texts.add('$applied');
    }
    return texts;
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
