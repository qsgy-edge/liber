import 'dart:typed_data';

import '../domain/contracts.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'book_source_webview_adapter.dart';
import 'html_rule_adapter.dart';
import 'html4_unescape.dart';
import 'java_regex.dart';
import 'js_source_runtime.dart';
import 'rule_field.dart';
import 'source_host_dispatcher.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';
import 'source_page_results.dart';
import 'source_url_rules.dart';
import 'source_stage_diagnostic.dart';

// A declared scalar has one native Text job or one raw TextList job. Literal
// and script-only fields need neither; the stage still runs one declared batch.
typedef _HtmlScalarJob = ({HtmlString? text, HtmlStringList? raw});

class HtmlBook {
  const HtmlBook({
    required this.url,
    this.rawAddress,
    this.preOptionUrl,
    required this.title,
    this.author = '',
    this.intro = '',
    this.cover = '',
    this.kind = '',
    this.lastChapter = '',
    this.wordCount = '',
  });
  final Uri url;

  /// The pipeline-resolved target before request-option transformations, with
  /// query encoding applied. JSON's [url] can already include an option's `js`
  /// result, so it cannot supply this identity target. Null when the carrier
  /// has no recorded analysis base (for example a book rebuilt from storage).
  final Uri? preOptionUrl;

  /// The address text this book was built from, option tail included, or null
  /// when the caller only has the URL.
  ///
  /// The frozen keeps `Book.bookUrl` as the resolved absolute address with its
  /// option tail untouched (`BookList.kt:272`, `AnalyzeRule.kt:317-323`). This
  /// fetch carrier can still hold the rule's relative text; [identityAddress]
  /// supplies that book identity. Every fetch parses the `,{…}` options from
  /// this text (`AnalyzeUrl.kt:214-222`). A `Uri` cannot carry the tail:
  /// `Uri.toString()` percent-encodes it, so the split finds nothing and the
  /// encoded tail reaches the site inside the query (#97). This is the
  /// counterpart of [SourceChapter.rawAddress] for a book.
  final String? rawAddress;

  /// The address text a fetch parses: the one this book was built from when it
  /// was kept, and the URL text otherwise. A bare URL carries no options, so it
  /// parses to itself.
  String get address => rawAddress ?? '$url';

  /// The frozen book identity (`BookList.kt:272`, `AnalyzeRule.kt:317-323`):
  /// without a raw carrier, keep the URL text; an absolute raw address stays
  /// verbatim; a relative one uses [preOptionUrl] plus the splitter's raw tail
  /// substring. `hasScheme` is also the pipelines' absolute-address test.
  /// Unlike `BookChapter.getAbsoluteURL()`, which resolves lazily, a book
  /// stores its resolved address. Without a recorded pre-option target, keep
  /// the raw carrier verbatim rather than inferring identity from the request
  /// target [url]. The fetch carrier [address] is independent of this getter.
  String get identityAddress {
    final raw = rawAddress;
    if (raw == null) return '$url';
    final boundary = sourceUrlOptionBoundaryOf(raw);
    final path = boundary == null ? raw : raw.substring(0, boundary).trim();
    if (Uri.tryParse(path)?.hasScheme == true) return raw;
    final resolved = preOptionUrl;
    if (resolved == null) return raw;
    return boundary == null
        ? '$resolved'
        : '$resolved${raw.substring(boundary)}';
  }

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
    rawAddress: value['url'] as String,
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
  const _ListItem.element(this.dom, this.selection) : value = null;
  const _ListItem.value(this.value) : dom = null, selection = null;

  final String? dom;
  final List<SourceDomSelectionStep>? selection;
  final Object? value;
  bool get isElement => dom != null;

  Object? get content => !isElement
      ? value
      : <String, Object?>{
          '__dom': dom,
          '__selection': [
            for (final step in selection!)
              <String, Object?>{
                'rule': step.rule,
                if (step.parentIndex != null) 'parentIndex': step.parentIndex,
                if (step.cssSelect) 'cssSelect': true,
              },
          ],
        };
}

/// One step of the frozen element-list walk: the raw value a segment produced,
/// or the elements an extraction segment selected (each with the rule that
/// addresses it in the step's document).
class _ListStep {
  const _ListStep.raw(this.value)
    : elements = null,
      dom = null,
      selection = null;
  const _ListStep.elements(this.dom, this.selection, this.elements)
    : value = null;

  final Object? value;
  final List<_ListItem>? elements;
  final String? dom;
  final List<SourceDomSelectionStep>? selection;

  Object? get content => elements == null
      ? value
      : <String, Object?>{
          ...(_ListItem.element(dom, selection).content
              as Map<String, Object?>),
          '__elements': true,
        };
}

/// The frozen four-stage HTML pipeline over the Rust rule adapter.
///
/// Static scalar jobs share one batch over the original page. A nonempty
/// static kind uses a second batch for item list grouping; stateful fields
/// retain their own ordered reads through [HtmlRuleBatch].
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
  // Only TOC item getters expose the unfinished chapter address verbatim.
  String? _tocChapterAddress;

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
            'bookUrl': _book!.identityAddress,
            'author': _book!.author,
            'intro': _book!.intro,
            'coverUrl': _book!.cover,
            'kind': _book!.kind,
            'latestChapterTitle': _book!.lastChapter,
            'wordCount': _book!.wordCount,
          },
    'chapter': _chapter == null
        ? null
        : {
            'title': _chapter!.name,
            'url': _tocChapterAddress ?? '${_chapter!.url}',
          },
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
    bool elementsResult = false,
  }) async {
    try {
      return await _runtime.evaluate(
        source: script,
        input: {
          ..._scriptInput(keyword, result, content: content),
          if (elementsResult) '__elementsResult': true,
        },
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
        initialResponse: response,
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
      diagnoseRequest: false,
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
    final (url, options) = await _request(stage.base, stage.address, _keyword);
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
  /// [content] is the actual content object for this read, bound as `src`.
  /// Stateful item fields supply their own node or scripted value; document
  /// fields supply the page String. Nested reads use the same complete scalar
  /// path, including its caller tail, before writing or substituting the value.
  RuleFieldContext _ruleContext(
    String label,
    Object? content, {
    RuleScriptEvaluator? evaluator,
  }) => RuleFieldContext(
    evaluateScript:
        evaluator ??
        (script, result) =>
            _evalJs(script, _keyword, result, label: label, content: content),
    extract: (_, rule) async => rule.isEmpty
        ? ''
        : await _readScriptRule(
            SourceRuleRead(
              member: label,
              form: SourceRuleForm.string,
              rule: rule,
              content: content,
              analysisContent: content,
              evaluateScript:
                  evaluator ??
                  (script, result) => _evalJs(
                    script,
                    _keyword,
                    result,
                    label: label,
                    content: content,
                  ),
            ),
          ),
    readVariable: _readRuleVariable,
    writeVariable: _writeRuleVariable,
  );

  Future<String> _readRuleVariable(String key) async {
    if (key == 'bookName') return _book?.title ?? '';
    if (key == 'title' && _chapter != null) return _chapterTitle ?? '';
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
  /// attribute name. Raw `all` serialization uses the existing list output to
  /// retain script/style and serialized entities before a scalar's own tail.
  /// The tree is parsed from [SourceDomRead.html], which is the
  /// document the node came from, so a node's own `select` scopes to its
  /// subtree exactly as jsoup's does.
  Future<Object?> _domOp(SourceDomRead read) async {
    final batch = HtmlRuleBatch(read.html);
    final selection = batch.selection('node', read.selection);
    if (read.op == SourceDomOp.count) {
      await batch.run();
      return selection.length;
    }
    if (read.op == SourceDomOp.attribute) {
      final value = batch.rawAttribute('attribute', read.extract, selection);
      await batch.run();
      return value.values;
    }
    final values = read.extract == 'all'
        ? batch.elementsTextList('value', '@all', selection)
        : batch.elementsText('value', '@${read.extract}', selection);
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
    return RuleField.resolve(
      raw,
      _ruleContext(label, content),
      content: content,
    );
  }

  /// One `java.getString`/`getStringList`/`getElement`/`getElements` call from a
  /// rule script — the frozen `AnalyzeRule.getString` and its three siblings
  /// (`AnalyzeRule.kt:159,166,246,252,259,328,363`) — read by *this* adapter's
  /// rule path over the content object the member was given: the same
  /// [RuleField] path and Rust extraction this stage reads its own fields with,
  /// not a second engine (ADR 0012).
  ///
  /// HTML `getElements` shares the ordered element-list walk and existing node
  /// descriptors. `getElement` remains a named refusal. The string-list form
  /// retains this adapter's `AnalyzeRule.getStringList` path ([_declareList]).
  Future<Object?> _readScriptRule(SourceRuleRead read) async {
    if (read.form == SourceRuleForm.elements) {
      final step = await _walkElements(
        read.rule,
        read.content,
        read.member,
        read.evaluateScript,
      );
      final elements = step.elements;
      if (elements != null) return step.content;
      final value = step.value;
      if (value == null) return const <Object?>[];
      if (value is List) return value;
      // Unlike the stage's item conversion, the frozen final List cast does
      // not turn a scalar into one item or split a string on newlines.
      throw UnsupportedError('${read.member} 的脚本结果不是列表：${read.rule}');
    }
    if (read.form == SourceRuleForm.element) {
      throw SourceScriptError(
        'policy',
        '${read.member} 无法回答 HTML 内容的元素对象：本产品的 HTML 规则引擎只回答文本，'
            '请用 java.getString/java.getStringList',
      );
    }
    final field = await RuleField.resolve(
      read.rule,
      _ruleContext(
        read.member,
        read.analysisContent,
        evaluator: read.evaluateScript,
      ),
      content: read.content,
    );
    final node = read.content is Map && (read.content as Map)['__dom'] is String
        ? _listItemOf(read.content)
        : null;
    if (read.form == SourceRuleForm.stringList) {
      if (field.scripts.isNotEmpty) {
        throw SourceScriptError(
          'policy',
          '${read.member} 暂不支持带脚本的列表规则：${read.rule}',
        );
      }
      if (field.isLiteralValue) {
        final contentText = node == null
            ? '${read.content}'
            : await _itemContentText(node);
        return _kindTexts(
          await field.apply(
            read.content,
            forValue: true,
            forStringList: true,
            contentText: contentText,
          ),
        );
      }
      final batch = HtmlRuleBatch(node?.dom ?? '${read.content}');
      final job = node == null
          ? batch.documentTextList('rule', field.extractionRule!)
          : batch.elementsTextList(
              'rule',
              field.extractionRule!,
              batch.selection('item', node.selection!),
            );
      await batch.run();
      return job.values;
    }
    if (node != null) {
      return _itemFieldValue(node, field, read.member, raw: read.rule);
    }
    final extracted = field.hasValueExtraction
        ? await _eagerExtract(
            read.content,
            field.extractionRule!,
            deferTail: _deferScriptScalarTail(field),
          )
        : read.content;
    return _scalarTail(
      field,
      await field.apply(
        extracted,
        forValue: true,
        contentText: '${read.content}',
      ),
    );
  }

  /// One per-element value rule. Shapes needing substitution or scripts are
  /// resolved by [_itemFieldValue] against each actual item, exactly once;
  /// static extraction fields keep the page batch.
  Future<RuleField?> _elementField(
    String raw, {
    required String content,
    String label = '',
  }) async => RuleField.requiresItemResolution(raw)
      ? null
      : await _field(raw, content: content, label: label);

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
  ) async => _itemsOfStep(
    await _walkElements(
      raw,
      body,
      label,
      (script, result) => _evalJs(
        script,
        _keyword,
        result,
        label: label,
        content: body,
        elementsResult: true,
      ),
    ),
  );

  /// `AnalyzeRule.getElements` (363–390) changes `result` each segment while
  /// the callback retains the analysis's original `src`. Unlike its scalar
  /// siblings, this walk does not call `SourceRule.makeUpRule(result)`.
  Future<_ListStep> _walkElements(
    String raw,
    Object? content,
    String label,
    SourceRuleScript evaluateScript,
  ) async {
    var step = _ListStep.raw(content);
    for (final segment in parseRuleFieldSegments(raw)) {
      if (step.elements == null && step.value == null) continue;
      if (segment.isScript) {
        final value = await evaluateScript(segment.text, step.content);
        step =
            value is Map &&
                value['__elements'] == true &&
                value['__dom'] is String
            ? await _selectList(
                value['__dom'] as String,
                sourceDomSelectionOf(value),
              )
            : _ListStep.raw(value);
      } else {
        step = await _listExtract(step, segment.text, label);
      }
    }
    return step;
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
      // AnalyzeByJSoup(Elements) parses Elements.toString(), unlike Element's
      // original-node path. Keep physically repeated markup through this edge.
      final batch = HtmlRuleBatch(step.dom!);
      final html = batch.elementsTextList(
        'html',
        '@all',
        batch.selection('items', step.selection!),
      );
      await batch.run();
      step = _ListStep.raw(html.values.join('\n'));
    }
    final String dom;
    final List<SourceDomSelectionStep> path;
    final value = step.value;
    if (value is Map) {
      final source = value['__dom'];
      if (source is! String) {
        throw UnsupportedError('$label 的脚本结果不是可提取的文档：$rule');
      }
      dom = source;
      path = [
        ...sourceDomSelectionOf(value),
        (rule: rule, parentIndex: null, cssSelect: false),
      ];
    } else if (value is String) {
      dom = value;
      path = [(rule: rule, parentIndex: null, cssSelect: false)];
    } else {
      throw UnsupportedError('$label 的脚本结果不是文本或元素，无法继续提取：$rule');
    }
    return _selectList(dom, path);
  }

  Future<_ListStep> _selectList(
    String dom,
    List<SourceDomSelectionStep> path,
  ) async {
    final batch = HtmlRuleBatch(dom);
    final selection = batch.selection('items', path);
    await batch.run();
    return _ListStep.elements(dom, path, [
      for (var index = 0; index < selection.length; index++)
        _ListItem.element(dom, [
          ...path,
          (rule: ':root', parentIndex: index, cssSelect: false),
        ]),
    ]);
  }

  /// The items one scripted element-list rule's final value carries: an element
  /// selection, a string list the frozen `AnalyzeRule.getStringList` splits on
  /// newlines, or a script's own array (element descriptors, strings, objects).
  List<_ListItem> _itemsOfStep(_ListStep step) {
    final elements = step.elements;
    if (elements != null) {
      return elements;
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
      return _ListItem.element(
        value['__dom'] as String,
        sourceDomSelectionOf(value),
      );
    }
    return _ListItem.value(value);
  }

  Future<String> _itemFieldValue(
    _ListItem item,
    RuleField? resolved,
    String label, {
    String raw = '',
    bool url = false,
    bool forStringList = false,
  }) async {
    final Object? content = item.content;
    final field =
        resolved ??
        await RuleField.resolve(
          raw,
          _ruleContext(label, content),
          content: content,
        );
    var needsContentText = false;
    if (field.isLiteralValue) {
      // Match RuleField's removal of one original mode head. A head produced
      // by an interpolation stays literal, as in the retained mode controls.
      final original = RuleField.extractionText(raw) ?? '';
      final headLength = original.startsWith('@@')
          ? 2
          : original.toLowerCase().startsWith('@json:')
          ? 6
          : original.toLowerCase().startsWith('@xpath:')
          ? 7
          : 0;
      final literal = splitRuleFields(
        field.extractionRule!.substring(headLength),
      );
      needsContentText =
          literal.rule.isEmpty &&
          (forStringList || literal.regex?.isNotEmpty == true);
    }
    final String contentText;
    if (item.isElement && needsContentText) {
      contentText = await _itemContentText(item);
    } else {
      // Plain scripted string items retain their own text. A script-produced
      // object is not a proven Java container and cannot serialize descriptors.
      contentText = item.value is String ? item.value as String : '';
    }
    final deferTail = !forStringList && _deferScriptScalarTail(field);
    Object? extracted = content;
    if (field.hasValueExtraction) {
      final batch = HtmlRuleBatch(item.isElement ? item.dom! : contentText);
      if (deferTail) {
        final rule = splitRuleFields(field.extractionRule!).rule;
        final values = item.isElement
            ? batch.elementsTextList(
                'value',
                rule,
                batch.selection('item', item.selection!),
              )
            : batch.documentTextList('value', rule);
        await batch.run();
        extracted = _rawScalarValue(field, values.values, url: url);
      } else if (item.isElement) {
        final selection = batch.selection('item', item.selection!);
        if (forStringList) {
          final values = batch.elementsTextList(
            'value',
            field.extractionRule!,
            selection,
          );
          await batch.run();
          extracted = values.values;
        } else {
          final values = batch.elementsText(
            'value',
            field.extractionRule!,
            selection,
          );
          await batch.run();
          extracted = values.values.firstOrNull ?? '';
        }
      } else if (forStringList) {
        final values = batch.documentTextList('value', field.extractionRule!);
        await batch.run();
        extracted = values.values;
      } else {
        final value = batch.documentText('value', field.extractionRule!);
        await batch.run();
        extracted = value.value;
      }
    }
    if (!forStringList && !deferTail && extracted is String) {
      extracted = _urlFallback(field, extracted, url);
    }
    final applied = await field.apply(
      extracted,
      forValue: true,
      contentText: contentText,
      forStringList: forStringList,
    );
    if (forStringList) return _kindTexts(applied).join(',');
    return _scalarTail(field, applied);
  }

  Future<String> _itemContentText(_ListItem item) async {
    final batch = HtmlRuleBatch(item.dom!);
    final selection = batch.selection('item', item.selection!);
    final html = batch.elementsTextList('html', '@all', selection);
    await batch.run();
    return html.values.firstOrNull ?? '';
  }

  List<String> _kindTexts(Object? value) => value is String
      ? value.split('\n')
      : value is List
      ? [for (final item in value) '$item']
      : const [];

  bool _deferScriptScalarTail(RuleField field, {bool unescape = true}) =>
      unescape &&
      field.hasValueExtraction &&
      field.scripts.isNotEmpty &&
      splitRuleFields(field.extractionRule!).rule.isNotEmpty;

  String? _rawScalarValue(
    RuleField field,
    List<String> values, {
    bool url = false,
  }) {
    // AnalyzeByJSoup.getString joins; getString0 (URL) takes the first and
    // keeps an empty String so JS may supply an address when nothing matched.
    final text = url
        ? values.firstOrNull ?? ''
        : values.isEmpty
        ? null
        : values.join('\n');
    return text == null
        ? null
        : applyRuleReplacement(
            text,
            splitRuleFields(field.extractionRule!),
            label: 'HTML',
          );
  }

  String _scalarTail(RuleField field, Object? value, {bool unescape = true}) {
    final text = '${value ?? ''}';
    return (field.isLiteralValue ||
                field.isScriptOnly ||
                _deferScriptScalarTail(field, unescape: unescape)) &&
            unescape
        ? unescapeHtml4(text)
        : text;
  }

  /// The URL mode's replacement when the extraction found nothing, as
  /// [_perElement] applies it.
  String _urlFallback(RuleField field, String value, bool url) =>
      url && value.isEmpty && field.hasValueExtraction
      ? applyRuleReplacement(
          '',
          splitRuleFields(field.extractionRule!),
          label: 'HTML',
        )
      : value;

  /// Declares a finished native Text read or a raw match-list read for a
  /// scripted scalar. Literal/script-only fields declare neither job.
  ///
  /// [rawEntities] reads a value-rule extraction through the frozen
  /// `AnalyzeRule.getString(rule, unescape = false)` shape (no entity pass),
  /// which the content stage needs; every other field keeps the default read.
  _HtmlScalarJob _declare(
    HtmlRuleBatch batch,
    String id,
    RuleField field, {
    bool unescape = true,
    bool rawEntities = false,
  }) {
    if (!field.hasValueExtraction) return (text: null, raw: null);
    if (_deferScriptScalarTail(field, unescape: unescape)) {
      return (
        text: null,
        raw: batch.documentTextList(
          id,
          splitRuleFields(field.extractionRule!).rule,
        ),
      );
    }
    return (
      text: rawEntities
          ? batch.documentTextRaw(id, field.extractionRule!)
          : batch.documentText(id, field.extractionRule!),
      raw: null,
    );
  }

  /// Declares the *list* read of one field (the frozen
  /// `AnalyzeRule.getStringList`), or none when the field is a script only. The
  /// frozen reads a page's next-page rule only as a list, so a `##` field on it
  /// runs per declared item and its values reach the walk as the extraction left
  /// them; a single-value field keeps [_declare].
  HtmlStringList? _declareList(
    HtmlRuleBatch batch,
    String id,
    RuleField field,
  ) => field.isScriptOnly || field.isLiteralValue
      ? null
      : batch.documentTextList(id, field.extractionRule!);

  /// Reads one declared document job with the field's scripts applied. A
  /// script-only field receives the page String; an extraction followed by
  /// scripts receives the raw matches before its own final scalar tail.
  Future<String> _documentValue(
    _HtmlScalarJob? job,
    RuleField field,
    String content, {
    bool url = false,
    bool unescape = true,
  }) async {
    final raw = job?.raw;
    final Object? value = !field.hasValueExtraction
        ? content
        : raw != null
        ? _rawScalarValue(field, raw.values, url: url)
        : job!.text!.value;
    final resolved =
        raw == null &&
            url &&
            value is String &&
            value.isEmpty &&
            field.hasValueExtraction
        ? applyRuleReplacement(
            '',
            splitRuleFields(field.extractionRule!),
            label: 'HTML',
          )
        : value;
    return _scalarTail(
      field,
      await field.apply(resolved, forValue: true, contentText: content),
      unescape: unescape,
    );
  }

  /// One rule through the Rust adapter on its own, for the rule-field forms that
  /// need a value *before* the stage's batch is declared: a `@put:` value and a
  /// `{{$.x}}` interpolation. A field without those never reaches this, so the
  /// one-bridge-call-per-stage shape is kept for every page that does not use
  /// them.
  Future<Object?> _eagerExtract(
    Object? value,
    String rule, {
    bool deferTail = false,
  }) async {
    if (deferTail) {
      final fields = splitRuleFields(rule);
      final descriptor = value is Map && value['__dom'] is String
          ? value
          : null;
      final batch = HtmlRuleBatch(
        descriptor != null ? descriptor['__dom'] as String : '$value',
      );
      final values = descriptor != null
          ? batch.elementsTextList(
              'value',
              fields.rule,
              batch.selection('item', sourceDomSelectionOf(descriptor)),
            )
          : batch.documentTextList('value', fields.rule);
      await batch.run();
      return values.values.isEmpty
          ? null
          : applyRuleReplacement(
              values.values.join('\n'),
              fields,
              label: 'HTML',
            );
    }
    if (value is Map && value['__dom'] is String) {
      final batch = HtmlRuleBatch(value['__dom'] as String);
      final selection = batch.selection('item', sourceDomSelectionOf(value));
      final job = batch.elementsText('value', rule, selection);
      await batch.run();
      return job.values.firstOrNull;
    }
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
      '${await field.apply(url && value.isEmpty ? applyRuleReplacement('', splitRuleFields(field.extractionRule!), label: 'HTML') : value, forValue: true) ?? ''}',
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
              ))?.toString() ??
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
    bool diagnoseRequest = true,
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
          : await host.forExecution(_cancellation).withSourceRateLimit(render);
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
    SourceStageHttpDetails? httpResponse;
    if (host != null) {
      final response = await sourceStageRequest(
        diagnose: diagnoseRequest,
        stage: stage,
        url: url,
        request: () => host
            .forExecution(_cancellation)
            .request(
              method,
              '$url',
              headers: headers,
              body: body,
              retry: options.retry,
            ),
      );
      text = response.body;
      finalUrl = response.url;
      statusCode = response.statusCode;
      responseHeaders = response.headers;
      httpResponse = (
        statusCode: response.statusCode,
        bodyByteLength: response.bodyByteLength,
        url: response.url,
      );
    } else {
      if (method != 'GET' || headers.isNotEmpty) {
        throw UnsupportedError('当前 transport 不支持 HTTP 请求选项');
      }
      text = await sourceStageRequest(
        diagnose: diagnoseRequest,
        stage: stage,
        url: url,
        request: () => transport.request(stage: stage, path: '$url'),
      );
    }
    _cancellation.throwIfCancelled();
    trace.add(BookSourceTraceEntry(stage: stage, path: '$url'));
    return SourceStageResponse(
      body: text,
      url: finalUrl,
      statusCode: statusCode,
      headers: responseHeaders,
      httpResponse: httpResponse,
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
    final searchFields = <String, RuleField?>{
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
        entry.key:
            (scriptedItems == null &&
                entry.key != 'kind' &&
                entry.value?.hasValueExtraction == true)
            ? batch.elementsText(
                entry.key,
                entry.value!.extractionRule!,
                items!,
              )
            : null,
    };
    // Dynamic item reads retain the original page and final selection index.
    await batch.run();
    final count = scriptedItems?.length ?? items!.length;
    // The frozen companion to the branch above: an empty element list and no
    // `bookUrlPattern` mean the page is a detail page too (`BookList.kt:88-99`).
    if (count == 0 && bookUrlPattern.isEmpty) {
      return _detailPageBooks(finalUrl, html);
    }

    final kindJobs = <HtmlStringList>[];
    if (scriptedItems == null &&
        kind?.hasValueExtraction == true &&
        _rule('ruleSearch', 'kind', optional: true).isNotEmpty) {
      // TextList flattens contexts. A second batch uses explicit per-item jobs.
      final kindBatch = HtmlRuleBatch(html);
      final root = kindBatch.elements('items', listRule.extractionRule!);
      for (var index = 0; index < count; index++) {
        final focus = kindBatch.elements(
          'kind-item:$index',
          ':root',
          parent: root,
          parentIndex: index,
        );
        kindJobs.add(
          kindBatch.elementsTextList(
            'kind:$index',
            kind!.extractionRule!,
            focus,
          ),
        );
      }
      await kindBatch.run();
    }

    Future<String> fieldValue(String key, int index, {bool url = false}) async {
      if (key == 'kind' && _rule('ruleSearch', key, optional: true).isEmpty) {
        return '';
      }
      final field = searchFields[key];
      if (key == 'kind' && kindJobs.isNotEmpty) {
        return _kindTexts(
          await field!.apply(
            kindJobs[index].values,
            forValue: true,
            forStringList: true,
          ),
        ).join(',');
      }
      if (scriptedItems != null ||
          field == null ||
          !field.hasValueExtraction ||
          key == 'kind') {
        final item = scriptedItems != null
            ? scriptedItems[index]
            : _ListItem.element(html, [
                (
                  rule: listRule.extractionRule!,
                  parentIndex: null,
                  cssSelect: false,
                ),
                (rule: ':root', parentIndex: index, cssSelect: false),
              ]);
        return _itemFieldValue(
          item,
          field,
          'ruleSearch.$key',
          raw: _rule('ruleSearch', key, optional: true),
          url: url,
          forStringList: key == 'kind',
        );
      }
      return (await _perElement(field, [
        jobs[key]!.values[index],
      ], url: url)).single;
    }

    final books = <HtmlBook>[];
    for (var index = 0; index < count; index++) {
      // Stateful fields follow BookList's per-item getter order. The page's
      // pure extraction fields were already obtained by the single batch.
      final title = await fieldValue('name', index);
      final authorValue = await fieldValue('author', index);
      final kindValue = await fieldValue('kind', index);
      final wordCountValue = await fieldValue('wordCount', index);
      final lastChapterValue = await fieldValue('lastChapter', index);
      final introValue = await fieldValue('intro', index);
      final link = await fieldValue('bookUrl', index, url: true);
      // The address text the rule produced, option tail included: it is what
      // this book keeps ([HtmlBook.rawAddress]) and what the details request
      // parses, exactly as the frozen stores `book.bookUrl` (#97).
      final bookAddress = link.trim().isEmpty
          ? '$finalUrl'
          : _required([link], 0, 'ruleSearch.bookUrl');
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
          preOptionUrl: bookUrlTarget,
          rawAddress: bookAddress,
          title: _required([title], 0, 'ruleSearch.name'),
          author: authorValue,
          intro: formatSourceIntro(introValue),
          lastChapter: lastChapterValue,
          wordCount: formatSourceWordCount(wordCountValue),
          kind: kindValue,
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
    _tocChapterAddress = null;
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
    final (book, tocText) = await _readBookInfo(html, infoUrl, hit);
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
    SourceStageResponse? finalTocResponse;
    tocPages = 0;
    var firstPage = true;
    // The frozen page walk (`BookChapterList.kt:48-121`): this page, then the
    // pages its `nextTocUrl` list declares, one at a time and in declared order.
    void clearTocChapter() {
      _chapter = null;
      _chapterTitle = null;
      _tocChapterAddress = null;
    }

    void publishTocChapter(String title, String address) {
      _chapter = SourceChapter(title, Uri(), rawAddress: address);
      _chapterTitle = title;
      _tocChapterAddress = address;
    }

    String tocFallbackAddress(SourcePageRequest request) {
      if (request.address.isEmpty) {
        return bookRequest?.address ?? hit.address;
      }
      final parts = splitSourceUrlOptions(request.address);
      final address = Uri.parse(parts.path);
      if (address.hasScheme) {
        return request.address;
      }
      return '${request.base.resolveUri(address)}${parts.tail}';
    }

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
        clearTocChapter();
        try {
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
          finalTocResponse = fetched;
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
          final tocFields = <String, RuleField?>{
            'chapterName': nameField,
            'chapterUrl': urlField,
            'updateTime': tagField,
            'isVolume': volumeField,
            'isVip': vipField,
            'isPay': payField,
          };
          final jobs = <String, HtmlStringList?>{
            for (final entry in tocFields.entries)
              entry.key:
                  (scriptedItems == null &&
                      entry.value?.hasValueExtraction == true)
                  ? batch.elementsText(
                      entry.key,
                      entry.value!.extractionRule!,
                      items!,
                    )
                  : null,
          };
          // The frozen reads a page's next-URL rule only on the pages it walks
          // through; the declared-list branch parses its pages with
          // `getNextUrl = false` (`BookChapterList.kt:104-121`).
          final next = readNext
              ? await _elementField(
                  _rule('ruleToc', 'nextTocUrl', optional: true),
                  content: page,
                  label: 'ruleToc.nextTocUrl',
                )
              : null;
          final nextValue = next == null
              ? null
              : _declareList(batch, 'next', next);
          await batch.run();
          // Complete next after list acquisition and before any item getter,
          // including the empty-list policy (BookChapterList.kt:187-207).
          var nextTexts = const <String>[];
          if (readNext) {
            final field =
                next ??
                await _field(
                  _rule('ruleToc', 'nextTocUrl', optional: true),
                  content: page,
                  label: 'ruleToc.nextTocUrl',
                );
            var job = nextValue;
            if (next == null && !field.isScriptOnly && !field.isLiteralValue) {
              final nextBatch = HtmlRuleBatch(page);
              job = _declareList(nextBatch, 'next', field);
              await nextBatch.run();
            }
            nextTexts = await _pageTexts(job, field, page);
          }
          final count = scriptedItems?.length ?? items!.length;
          if (count == 0) {
            throw SourceStageDiagnostic.response(
              stage: BookSourceStage.tableOfContents,
              url: fetched.url,
              body: fetched.body,
              httpResponse: fetched.httpResponse,
            );
          }
          Future<String> fieldValue(
            String key,
            int index, {
            bool url = false,
          }) async {
            final field = tocFields[key];
            if (scriptedItems != null ||
                field == null ||
                !field.hasValueExtraction) {
              final item = scriptedItems != null
                  ? scriptedItems[index]
                  : _ListItem.element(page, [
                      (
                        rule: listRule.extractionRule!,
                        parentIndex: null,
                        cssSelect: false,
                      ),
                      (rule: ':root', parentIndex: index, cssSelect: false),
                    ]);
              return _itemFieldValue(
                item,
                field,
                'ruleToc.$key',
                raw: _rule('ruleToc', key, optional: true),
                url: url,
              );
            }
            return (await _perElement(field, [
              jobs[key]!.values[index],
            ], url: url)).single;
          }

          // Only ordinary empty URLs need this text; cache it lazily per page.
          late final ordinaryFallbackAddress = tocFallbackAddress(request);
          for (var index = 0; index < count; index++) {
            publishTocChapter('', '');
            try {
              final title = await fieldValue('chapterName', index);
              publishTocChapter(title, '');
              final address = await fieldValue('chapterUrl', index, url: true);
              publishTocChapter(title, address);
              final tagValue = await fieldValue('updateTime', index);
              final volumeValue = await fieldValue('isVolume', index);
              final isVolume = sourceIsTrue(volumeValue);
              // Tag/volume observe the raw address; VIP/pay observe its fallback.
              publishTocChapter(
                title,
                address.isEmpty
                    ? (isVolume ? '$title$index' : ordinaryFallbackAddress)
                    : address,
              );
              // URL/tag/volume complete even for a skipped item; VIP/pay belong
              // inside the frozen nonempty-title condition (BookChapterList:244).
              if (title.isEmpty) continue;
              final vipValue = await fieldValue('isVip', index);
              final payValue = await fieldValue('isPay', index);
              final tag = tagValue.isEmpty ? null : tagValue;
              final isVip = sourceIsTrue(vipValue);
              final isPay = sourceIsTrue(payValue);
              final SourceChapter chapter;
              if (address.isEmpty) {
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
                final rawAddress = address;
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
            } finally {
              clearTocChapter();
            }
          }
          return (pageUrl: pageUrl, items: nextTexts);
        } finally {
          clearTocChapter();
        }
      },
    );
    if (chapters.isEmpty) {
      throw SourceStageDiagnostic.response(
        stage: BookSourceStage.tableOfContents,
        url: finalTocResponse?.url ?? tocTarget,
        body: finalTocResponse?.body ?? '',
        httpResponse: finalTocResponse?.httpResponse,
      );
    }
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
    );
    return book.title.isEmpty ? const <HtmlBook>[] : <HtmlBook>[book];
  }

  /// The `ruleBookInfo` rules over a response this pipeline already has.
  ///
  /// [details] fetches its own response and reads the TOC address from it; the
  /// search stage calls this for a response whose final URL matched
  /// `bookUrlPattern` (`BookList.kt:53-70`) or for the empty-element-list
  /// fallback (`BookList.kt:91`), where the frozen `getInfoItem` runs the same
  /// getters over that response. The fallback ignores the completed TOC address
  /// and issues no TOC request.
  ///
  /// [hit] is the book the rules start from. A search synthesizes an empty one,
  /// so the detail page's own name and author are taken, exactly as the frozen
  /// empty `Book` takes them (`BookInfo.kt:60-73`).
  Future<(HtmlBook, String)> _readBookInfo(
    String html,
    Uri infoUrl,
    HtmlBook hit,
  ) async {
    _book = hit;
    final batch = HtmlRuleBatch(html);
    final rawFields = <String, String>{
      for (final key in [
        'name',
        'author',
        'kind',
        'wordCount',
        'lastChapter',
        'intro',
        'coverUrl',
      ])
        key: _rule('ruleBookInfo', key, optional: true),
      'tocUrl': _rule('ruleBookInfo', 'tocUrl', optional: true),
    };
    final fields = <String, RuleField?>{};
    final jobs = <String, _HtmlScalarJob>{};
    HtmlStringList? kindJob;
    for (final entry in rawFields.entries) {
      final field = await _elementField(
        entry.value,
        content: html,
        label: 'ruleBookInfo.${entry.key}',
      );
      fields[entry.key] = field;
      if (field != null) {
        if (entry.key == 'kind') {
          if (field.hasValueExtraction) {
            kindJob = batch.documentTextList('kind', field.extractionRule!);
          }
        } else {
          jobs[entry.key] = _declare(batch, entry.key, field);
        }
      }
    }
    await batch.run();
    Future<String> read(String key, {bool url = false}) async {
      final prepared = fields[key];
      final field =
          prepared ??
          await _field(
            rawFields[key]!,
            content: html,
            label: 'ruleBookInfo.$key',
          );
      if (key == 'kind') {
        Object? value = html;
        if (field.hasValueExtraction) {
          if (prepared != null) {
            value = kindJob!.values;
          } else {
            final dynamicBatch = HtmlRuleBatch(html);
            final valueJob = dynamicBatch.documentTextList(
              'kind',
              field.extractionRule!,
            );
            await dynamicBatch.run();
            value = valueJob.values;
          }
        }
        return _kindTexts(
          await field.apply(
            value,
            forValue: true,
            forStringList: true,
            contentText: html,
          ),
        ).join(',');
      }
      if (prepared != null) {
        return _documentValue(jobs[key], field, html, url: url);
      }
      final dynamicBatch = HtmlRuleBatch(html);
      final job = _declare(dynamicBatch, key, field);
      await dynamicBatch.run();
      return _documentValue(job, field, html, url: url);
    }

    final canReName = _rule(
      'ruleBookInfo',
      'canReName',
      optional: true,
    ).trim().isNotEmpty;
    void publishBook({
      String? title,
      String? author,
      String? kind,
      String? wordCount,
      String? lastChapter,
      String? intro,
      String? cover,
    }) {
      final current = _book!;
      _book = HtmlBook(
        url: hit.url,
        // Refresh retains the original address and its request options (#97).
        rawAddress: hit.rawAddress,
        preOptionUrl: hit.preOptionUrl,
        title: title ?? current.title,
        author: author ?? current.author,
        kind: kind != null && kind.isNotEmpty ? kind : current.kind,
        wordCount: wordCount != null && wordCount.isNotEmpty
            ? wordCount
            : current.wordCount,
        lastChapter: lastChapter != null && lastChapter.isNotEmpty
            ? lastChapter
            : current.lastChapter,
        intro: intro != null && intro.isNotEmpty ? intro : current.intro,
        cover: cover != null && cover.isNotEmpty ? cover : current.cover,
      );
    }

    final detailsTitle = await read('name');
    final mergedTitle =
        detailsTitle.isNotEmpty && (canReName || hit.title.isEmpty)
        ? detailsTitle
        : hit.title;
    publishBook(title: mergedTitle);
    final detailsAuthor = await read('author');
    final mergedAuthor =
        detailsAuthor.isNotEmpty && (canReName || hit.author.isEmpty)
        ? detailsAuthor
        : hit.author;
    publishBook(author: mergedAuthor);
    final detailsKind = await read('kind');
    publishBook(kind: detailsKind);
    final detailsWordCount = formatSourceWordCount(await read('wordCount'));
    publishBook(wordCount: detailsWordCount);
    final detailsLastChapter = await read('lastChapter');
    publishBook(lastChapter: detailsLastChapter);
    final detailsIntro = formatSourceIntro(await read('intro'));
    publishBook(intro: detailsIntro);
    final coverText = await read('coverUrl', url: true);
    publishBook(
      cover: coverText.isEmpty ? '' : '${_resolve(infoUrl, coverText)}',
    );
    final book = _book!;
    final tocText = await read('tocUrl', url: true);
    return (book, tocText);
  }

  /// `ruleContent.content`, as the frozen content stage reads it.
  ///
  /// The field reaches the adapter whole, `##` parts and all: the frozen reads
  /// `contentRule.content` on its own (`BookContent.kt:177`) and a replacement
  /// the field itself declares belongs to that read. The stage's own
  /// `ruleContent.replaceRegex` is applied afterwards, to the joined text —
  /// see [_shapeJoinedContent].
  String _contentRule() => _rule('ruleContent', 'content');

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    if (book != null) _book = book;
    _tocChapterAddress = null;
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
          _contentRule(),
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
        final contentValue = _declare(
          batch,
          'content',
          content,
          unescape: false,
          rawEntities: true,
        );
        final nextValue = next == null
            ? null
            : _declareList(batch, 'next', next);
        await batch.run();
        final text = await _documentValue(
          contentValue,
          content,
          html,
          unescape: false,
        );
        if (text.isEmpty) {
          throw SourceStageDiagnostic.response(
            stage: BookSourceStage.content,
            url: fetched.url,
            body: fetched.body,
            httpResponse: fetched.httpResponse,
          );
        }
        // The frozen content stage turns one page's HTML into text here, before
        // the pages are joined (`BookContent.kt:178-181`): `formatKeepImg`,
        // then the `&`-guarded `unescapeHtml4`.
        parts.add(formatContentPage(text));
        return (
          pageUrl: pageUrl,
          items: await _pageTexts(nextValue, next, html),
        );
      },
    );
    final text = await _shapeJoinedContent(parts.join('\n'));
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
    if (field.isLiteralValue) {
      return sourceScriptTexts(
        await field.apply(
          page,
          forValue: true,
          forStringList: true,
          contentText: page,
        ),
      );
    }
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

  /// The frozen content stage's final shaping (`BookContent.kt:133-142`).
  ///
  /// Only when the source declares `ruleContent.replaceRegex` does the frozen
  /// stage shape the joined page text: it trims every line, reads the trimmed
  /// text through the declared replacement
  /// (`analyzeRule.getString(replaceRegex, contentStr)`), and prefixes every
  /// line — an empty line included — with the hard-coded two full-width spaces
  /// `"　　"`. A source that declares no `replaceRegex` is left exactly as
  /// extracted.
  Future<String> _shapeJoinedContent(String text) async {
    final replaceRegex = _rule('ruleContent', 'replaceRegex', optional: true);
    if (replaceRegex.isEmpty) return text;
    final trimmed = text.split('\n').map((line) => line.trim()).join('\n');
    final replaced = await _applyReplaceRegex(trimmed, replaceRegex);
    return replaced.split('\n').map((line) => '　　$line').join('\n');
  }

  /// One replacement field over the joined text: the frozen
  /// `AnalyzeRule.getString(replaceRegex, text)`.
  ///
  /// The field is resolved first, so the `{{...}}`/`@get:`/`@put:` substitution
  /// runs over the whole field before it splits on `##`, which is the frozen
  /// `SourceRule.makeUpRule` order (`AnalyzeRule.kt:600-695`); [text] is the
  /// value a `{{...}}` expression sees as `result`. The `##` parts then decide
  /// the read: the frozen skips the extraction when the rule part is blank and a
  /// regex is declared (`AnalyzeRule.kt:277-279`) — the shape every used
  /// source's replacement has — and otherwise reads the text through the
  /// adapter's engine, which applies the same replacement itself.
  Future<String> _applyReplaceRegex(String text, String field) async {
    final resolved = await _field(
      field,
      content: text,
      label: 'ruleContent.replaceRegex',
    );
    if (!resolved.hasValueExtraction) {
      return _scalarTail(
        resolved,
        await resolved.apply(text, forValue: true, contentText: text),
      );
    }
    final extraction = resolved.extractionRule!;
    final fields = splitRuleFields(extraction);
    if (fields.rule.isNotEmpty) {
      return '${await _eagerExtract(text, extraction) ?? ''}';
    }
    return applyRuleReplacement(text, fields, label: 'HTML');
  }
}
