import 'dart:convert';
import 'dart:typed_data';

import '../domain/contracts.dart';
import '../domain/store_message.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'book_source_webview_adapter.dart';
import 'java_regex.dart';
import 'html4_unescape.dart';
import 'json_source_rules.dart';
import 'js_source_runtime.dart';
import 'rule_field.dart';
import 'source_host_dispatcher.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';
import 'source_page_results.dart';
import 'source_url_rules.dart';
import 'source_stage_diagnostic.dart';

export 'source_stage_diagnostic.dart';

/// The base text the frozen `NetworkUtils.getAbsoluteURL(String?, String)`
/// overload builds its URL object from: everything before the first comma
/// (`NetworkUtils.kt:160-169`), so a `,{…}` option tail inside a base text never
/// becomes part of a resolved directory.
String _sourceUrlStringBase(String text) {
  final comma = text.indexOf(',');
  return comma < 0 ? text : text.substring(0, comma);
}

/// The two halves of one address text at the frozen option boundary
/// (`AnalyzeUrl.paramPattern`), read as text: everything before it, and the tail
/// verbatim, comma included.
///
/// A carrier keeps the tail exactly as the rule wrote it, because building a
/// chapter reads no option object. Only a request that actually consumes the
/// tail validates a family, so an unsupported one stays that request's named
/// refusal ([splitSourceUrlOptions]) instead of failing the table of contents.
({String before, String tail}) _sourceAddressParts(String address) {
  final boundary = sourceUrlOptionBoundaryOf(address);
  return boundary == null
      ? (before: address, tail: '')
      : (
          before: address.substring(0, boundary),
          tail: address.substring(boundary),
        );
}

/// One declared page address's own identity for a page walk's duplicate check:
/// its text before the frozen option boundary, resolved against the page it was
/// read from — or against [rawBase], the complete native text a retained page
/// hands a later page. Nothing the text declares runs here: the frozen
/// `NetworkUtils.getAbsoluteURL` builds no `AnalyzeUrl`, so no source header is
/// read, no template expands and no option is interpreted for an address the
/// walk may still discard. The page the walk really visits analyses its whole
/// text in its own visit.
Uri _declaredPageUrl(Uri base, String address, {String? rawBase}) {
  final boundary = sourceUrlOptionBoundaryOf(address);
  final native = sourceUrlTextResolved(
    base,
    boundary == null ? address : address.substring(0, boundary),
    rawBase: rawBase,
  );
  final uri = base.resolve(native);
  if (!['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Invalid source URL');
  }
  return uri;
}

/// One chapter's complete native `BookChapter.getAbsoluteURL()` text
/// (`BookChapter.kt:143-155`): [address] before its own frozen option boundary,
/// resolved against [base], then that same tail verbatim behind it.
///
/// The frozen content branch hands this whole text to its analysis as both of its
/// URLs (`WebBook.kt:311-329`), so the tail is part of the page base a later
/// page resolves against and its `..` segments take part in that resolution.
/// Deriving it here reads no option object and runs no script.
String _sourceAbsoluteText(String address, Uri base) {
  final parts = _sourceAddressParts(address);
  return '${sourceUrlTextResolved(base, parts.before)}${parts.tail}';
}

/// Whether an address text is pending analysis rather than a URI: a `{{…}}`
/// template in its address part, or one of the request-program spellings the
/// frozen grammar recognises — `@js:` or a closed `<js>…</js>` block, in either
/// case, anywhere in the text (`AppPattern.JS_PATTERN`, the same block
/// recognition [expandSourceUrl] runs).
///
/// A closed block can itself hold the `,{` characters the lexical option
/// boundary would cut at, so the block is matched on the whole text and only its
/// start decides whether it belongs to the address or to an ordinary option
/// tail: a program written inside option data is not this chapter's input.
///
/// Such text is carried, saved and rebuilt verbatim. It is never read as a URI —
/// a program's `@js:` is not a scheme, and a template's braces are not escapes —
/// and it runs only in the request that actually analyses it.
bool _isPendingAddressText(String address) {
  final boundary = sourceUrlOptionBoundaryOf(address);
  final path = (boundary == null ? address : address.substring(0, boundary))
      .trim();
  if (path.contains('{{')) return true;
  final block = RegExp(
    r'<js>([\s\S]*?)</js>|@js:([\s\S]*)',
    caseSensitive: false,
  ).firstMatch(address);
  return block != null && block.start < (boundary ?? address.length);
}

/// The pre-option target an ordinary empty chapter keeps when the TOC page's
/// own address stands in for a rule that answered nothing.
///
/// The complete request text remains separate; identity reads no request option
/// and does not depend on the information request that supplied the page.
Uri _ordinaryChapterTarget(String fallbackAddress, Uri pageUrl) {
  final boundary = sourceUrlOptionBoundaryOf(fallbackAddress);
  final path = boundary == null
      ? fallbackAddress
      : fallbackAddress.substring(0, boundary);
  // The native absolute shortcut is the Kotlin trim; a relative text keeps the
  // URL constructor's own original spelling.
  final trimmed = sourceKotlinTrim(path);
  final parsed = Uri.tryParse(trimmed);
  return parsed != null && parsed.hasScheme ? parsed : pageUrl.resolve(path);
}

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
    this.deferEntityVariables = false,
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

  /// Whether this analysis carries its own book/chapter variables instead of
  /// reading and writing the space's rows (#132).
  ///
  /// The candidate flow sets this: a preview of a row that already exists must
  /// not mutate it, and a failed or cancelled draft must leave it as it was.
  /// The candidate's variables live in [_entityDraft]; cookies, cache entries
  /// and `java.put`/`get` still use the shared host surface. Default false, so
  /// every existing caller keeps the direct row behavior.
  final bool deferEntityVariables;

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
  // Only TOC item getters expose the unfinished chapter address verbatim.
  String? _tocChapterAddress;

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

  /// The candidate-scoped book/chapter variables a deferred analysis carries,
  /// or null when this analysis reads and writes the space's rows directly.
  ///
  /// A field of this pipeline, so two candidates — even of one source over one
  /// host surface — never share a draft.
  late final SourceEntityVariableDraft? _entityDraft = deferEntityVariables
      ? SourceEntityVariableDraft()
      : null;

  /// The runtime's entity-variable store (#132): the candidate draft, the
  /// space's rows, and — while a TOC item is rebuilt — that item's own chapter
  /// scope, so a rebuilt chapter starts empty and keeps only its own writes.
  /// A details/TOC/content stage hands its final book and chapter text back
  /// through this same store, so the draft and the rows never mix.
  late final SourceEntityVariableScope _entityVariables =
      SourceEntityVariableScope(
        _entityDraft ?? _hostSurface,
        through: _entityDraft == null ? _hostSurface : null,
      );

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
    entityVariables: _entityVariables,
    androidId: androidId,
    onMessage: (message) => onHostMessage?.call(message),
    ruleEvaluator: _readScriptRule,
  );

  /// The headers the request being analysed carries: the source's own `header`
  /// rule, then the caller's. The frozen `AnalyzeUrl` constructor evaluates them
  /// for each new request — before that request's own address is expanded and
  /// its own options run, because a `<js>` header rule can itself reach the
  /// network (`AnalyzeUrl.kt:125-145`, `BaseSource.kt:103-130`) — and the
  /// request that read them sends that same map.
  Map<String, String> _activeHeaders = const {};

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
      stage.stage,
      stage.url,
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
  /// the runtime the adapter already owns, a value rule is extracted by the
  /// bounded JSON reader, and `@get:`/`@put:` read and write the source-scoped
  /// variables `java.get`/`java.put` use.
  ///
  /// [label] is the rule field being read (`ruleBookInfo.kind`): a script this
  /// field runs carries it into the failure it reports, so the interface and the
  /// source log name the field instead of the bare `js`.
  Object? _responseRoot;
  String? _responseText;
  Object? _nativeObjectRoot;

  Object? _analysisContent(Object? value) =>
      identical(value, _responseRoot) ? _responseText : value;

  String _analysisText(Object? value) => identical(value, _responseRoot)
      ? _responseText!
      : JsonSourceRules.contentText(value);

  Object? _extractionContent(Object? value) {
    if (value is String) {
      final text = value.trim();
      if ((text.startsWith('{') && text.endsWith('}')) ||
          (text.startsWith('[') && text.endsWith(']'))) {
        return jsonDecode(value);
      }
    }
    return value;
  }

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
        : await _field(
            content,
            rule,
            label: label,
            context: _ruleContext(label, content, evaluator: evaluator),
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
    bool unescape = true,
    RuleFieldContext? context,
  }) async {
    final content = _analysisContent(value);
    final field = await RuleField.resolve(
      rule,
      context ?? _ruleContext(label, content),
      content: content,
    );
    if (!raw && identical(value, _nativeObjectRoot) && value is Map) {
      final result = await field.applyNativeObject(value);
      return unescape ? unescapeHtml4('${result ?? ''}') : result;
    }
    final extracted = field.isScriptOnly || (!raw && field.isLiteralValue)
        ? content
        : raw
        ? JsonSourceRules.read(_extractionContent(value), field.extractionRule!)
        : JsonSourceRules.extract(
            _extractionContent(value),
            field.extractionRule!,
          );
    final result = await field.apply(
      extracted,
      forValue: !raw,
      contentText: _analysisText(value),
    );
    if (raw && field.isScriptOnly && result is Map) {
      _nativeObjectRoot = result;
    }
    return !raw && unescape ? unescapeHtml4('${result ?? ''}') : result;
  }

  /// The frozen category carrier is nullable: no kind rule, or an exactly empty
  /// one, leaves it unset. A declared rule that matches nothing still answers
  /// empty text.
  Future<String?> _kind(Object? value, String rule, {String label = ''}) async {
    if (rule.isEmpty) return null;
    final content = _analysisContent(value);
    final field = await RuleField.resolve(
      rule,
      _ruleContext(label, content),
      content: content,
    );
    if (identical(value, _nativeObjectRoot) && value is Map) {
      final result = await field.applyNativeObject(value, forStringList: true);
      return result is String
          ? result.split('\n').join(',')
          : result is List
          ? [for (final item in result) '$item'].join(',')
          : '';
    }
    return (await _resolvedStringList(value, field)).join(',');
  }

  /// The already-resolved ordinary JSON list boundary shared by kind and
  /// java.getStringList. Each replacement is per item; no scalar tail here.
  Future<List<String>> _resolvedStringList(
    Object? value,
    RuleField field,
  ) async {
    Object? extracted = _analysisContent(value);
    if (field.hasValueExtraction) {
      final fields = splitRuleFields(field.extractionRule!);
      extracted = [
        for (final item in JsonSourceRules.list(
          _extractionContent(value),
          fields.rule,
        ))
          fields.regex?.isNotEmpty == true
              ? applyRuleReplacement(JsonSourceRules.contentText(item), fields)
              : JsonSourceRules.contentText(item),
      ];
    }
    final result = await field.apply(
      extracted,
      forValue: true,
      forStringList: true,
      contentText: _analysisText(value),
    );
    final texts = result is String
        ? result.split('\n')
        : result is List
        ? [for (final item in result) '$item']
        : const <String>[];
    return texts;
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
  Future<String> _text(
    Object? value,
    String rule, {
    String label = '',
    bool unescape = true,
    SourceStageResponse? response,
  }) async {
    final result = await _field(value, rule, label: label, unescape: unescape);
    if (result == null || result.toString().isEmpty) {
      if (response != null) {
        throw SourceStageDiagnostic.response(
          stage: BookSourceStage.content,
          url: response.url,
          body: response.body,
          httpResponse: response.httpResponse,
        );
      }
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
    final context = _ruleContext(
      read.member,
      read.analysisContent,
      evaluator: read.evaluateScript,
    );
    if (read.form == SourceRuleForm.string) {
      return _field(
        read.content,
        read.rule,
        label: read.member,
        context: context,
      );
    }
    final field = await RuleField.resolve(
      read.rule,
      context,
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
        return _field(
          read.content,
          read.rule,
          label: read.member,
          context: context,
        );
      case SourceRuleForm.stringList:
        return _resolvedStringList(read.content, field);
      case SourceRuleForm.element:
        return JsonSourceRules.read(
          _extractionContent(read.content),
          field.extractionRule!,
        );
      case SourceRuleForm.elements:
        return JsonSourceRules.list(
          _extractionContent(read.content),
          field.extractionRule!,
        );
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
  /// Search can capture the same expanded address and its resolved identity
  /// before the option script changes the request target. No second expansion
  /// runs, and the captured tail belongs to the expanded address itself.
  Future<(Uri, SourceUrlOptions)> _request(
    Uri base,
    String template,
    String keyword, {
    void Function(Uri preOptionUrl, String expandedAddress)? captureIdentity,
    String? rawBase,
  }) async {
    final expandedAddress = await _expand(template, keyword);
    // A retained first page hands a later-page rule the complete native text as
    // its base (`WebBook.kt:311-329`): the declared address resolves against
    // that whole raw text first, so its option boundary is still text when the
    // address is read, and only this request splits it afterwards.
    var address = expandedAddress;
    final raw = rawBase;
    if (raw != null) {
      final parts = _sourceAddressParts(expandedAddress);
      address =
          '${sourceUrlTextResolved(base, parts.before, rawBase: raw)}${parts.tail}';
    }
    final split = splitSourceUrlOptions(address);
    Uri? capturedPreOption;
    if (captureIdentity != null) {
      capturedPreOption = _url(base, split.path);
      if (!split.options.isPost) {
        capturedPreOption = _url(
          base,
          await encodeSourceQuery(
            sourceUrlTextWithRawQuery(capturedPreOption, split.path),
            charset: split.options.charset,
          ),
        ).removeFragment();
      }
    }
    var url = _url(base, split.path);
    final script = split.options.js;
    // The frozen replaces the URL with the option script's result only when that
    // result is not null (`AnalyzeUrl.kt:238-242`: `evalJS(jsStr, url)
    // ?.toString()?.let { url = it }`). A script that only shows a toast answers
    // nothing, so the URL it was given stands — stringifying that nothing into
    // `'null'` sent the request to `/null` (a real source's search, #94).
    final text = script == null
        ? split.path
        : (await _evalJs(
                script,
                keyword,
                sourceUrlTextResolved(base, split.path),
              ))?.toString() ??
              split.path;
    url = _url(base, text);
    if (!split.options.isPost) {
      url = _url(
        base,
        await encodeSourceQuery(
          sourceUrlTextWithRawQuery(
            text.contains('?') ? url.removeFragment() : url,
            text,
          ),
          charset: split.options.charset,
        ),
      );
    }
    if (captureIdentity != null) {
      captureIdentity(capturedPreOption!, expandedAddress);
    }
    return (url, split.options);
  }

  /// One declared page's own request, in the frozen order: the source header it
  /// reads once (`AnalyzeUrl.kt:125-145`), then the whole address text expanded,
  /// its options split and its `js` run (`initUrl`, `:139-147`). [request] is a
  /// page the walk really reached, so an alias it discards never runs this.
  Future<(Uri, SourceUrlOptions)> _analyzeDeclaredPage(
    SourcePageRequest request, {
    String? rawBase,
  }) async {
    _activeHeaders = await _readHeaders();
    _cancellation.throwIfCancelled();
    return _request(request.base, request.address, _keyword, rawBase: rawBase);
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
    // This request's own map: its stage read the source header before it
    // analysed the address, and a `java.initUrl` reanalysis or a repeated send
    // of that same request keeps it.
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
          : await host.forExecution(_cancellation).withSourceRateLimit(render);
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
      trace.add(BookSourceTraceEntry(stage: stage, path: url.toString()));
      if ('${response.url}' != '$url') {
        trace.add(BookSourceTraceEntry(stage: stage, path: '${response.url}'));
      }
      _cancellation.throwIfCancelled();
      return SourceStageResponse(
        body: response.body,
        url: response.url,
        statusCode: response.statusCode,
        headers: response.headers,
        httpResponse: (
          statusCode: response.statusCode,
          bodyByteLength: response.bodyByteLength,
          url: response.url,
        ),
        wasRedirected: response.wasRedirected,
      );
    }
    if (method != 'GET' || headers.isNotEmpty) {
      throw UnsupportedError('当前 transport 不支持 HTTP 请求选项');
    }
    final text = await sourceStageRequest(
      diagnose: diagnoseRequest,
      stage: stage,
      url: url,
      request: () => transport.request(stage: stage, path: url.toString()),
    );
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
      final document = jsonDecode(response.body);
      _responseRoot = document;
      _responseText = response.body;
      return document;
    } on FormatException {
      throw SourceStageFormatError(
        stage: stage,
        address: sourceStageAddress(response.url),
        prefix: sourceStageBodyPrefix(response.body),
        httpResponse: response.httpResponse,
      );
    }
  }

  // Only these existing getters read the initialized book-info page. Their
  // bare keys depend on whether script-only init actually yields NativeObject.
  bool _deferBookInfoKey(Map raw, String field, String rule) {
    if (!(switch (field) {
      'name' ||
      'author' ||
      'kind' ||
      'wordCount' ||
      'lastChapter' ||
      'intro' ||
      'coverUrl' ||
      'tocUrl' => true,
      _ => false,
    })) {
      return false;
    }
    final init = raw['init'];
    if (init is! String) return false;
    final parts = parseRuleField(init);
    return parts.extractionRule == null &&
        parts.scripts.any((script) => script.trim().isNotEmpty) &&
        RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(rule);
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
          if (extraction != null &&
              !(key == 'ruleBookInfo' &&
                  _deferBookInfoKey(raw, '${entry.key}', extraction))) {
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

  /// One chapter address whose own request program has not run yet: the text
  /// that request will analyse, and the key this chapter names right now.
  ///
  /// A TOC chapter address is a completed rule value, not the request itself, so
  /// a `{{…}}` template or `@js:` program it still carries belongs to the
  /// request that fetches the chapter. The address is resolved passively against
  /// the TOC base this chapter was read from — a relative pending address keeps
  /// that directory, and a program is resolved as text instead of being parsed
  /// as a URI scheme — and that resolved representation names the chapter and is
  /// what the saved request text keeps. A whole program stays the rule's own
  /// text for the one request that runs it. [_url] keeps refusing a pending text
  /// wherever a request actually resolves its target.
  static ({String text, Uri target}) _pendingChapterAddress(
    Uri base,
    String address,
  ) {
    final parts = splitSourceUrlOptions(address);
    final resolved = resolveSourceTocUrl(
      address: address,
      base: base,
      fallbackAddress: address,
    );
    final bare = splitSourceUrlOptions(resolved).path;
    if (!_isPendingAddressText(address)) {
      return (text: resolved, target: _url(base, bare));
    }
    return (
      text: parts.path.startsWith('@js:') ? address : resolved,
      target: SourceHttpUri.parse(bare),
    );
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
    // This request's own source header, read before its address options run.
    _activeHeaders = await _readHeaders();
    late String searchIdentityAddress;
    final (url, options) = await _request(
      _base,
      source['searchUrl'] as String,
      keyword,
      captureIdentity: (_, expandedAddress) {
        searchIdentityAddress = expandedAddress;
      },
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
    final searchParts = splitSourceUrlOptions(searchIdentityAddress);
    final redirected = checked.wasRedirected ?? ('$finalUrl' != '$url');
    final identityAddress = redirected
        ? '$finalUrl'
        : (Uri.tryParse(searchParts.path)?.hasScheme == true
                  ? searchParts.path
                  : sourceUrlTextResolved(url, searchParts.path)) +
              searchParts.tail;
    // The frozen `getInfoItem` keeps `book.bookUrl` from one native URL operation
    // over the whole once-expanded rule text (`BookList.kt:159-163` over
    // `AnalyzeUrl.ruleUrl`), not from a resolution of its option-stripped path; a
    // redirected response keeps the URL it landed on.
    final comparisonAddress = redirected
        ? '$finalUrl'
        : sourceUrlTextResolved(url, searchIdentityAddress);
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
      return _detailPageBooks(
        document,
        finalUrl,
        identityAddress: identityAddress,
        comparisonAddress: comparisonAddress,
        infoHtml: checked.body,
      );
    }
    final found = await _elementList(
      document,
      search['bookList']!,
      label: 'ruleSearch.bookList',
    );
    // The frozen companion to the branch above: an empty element list and no
    // `bookUrlPattern` mean the page is a detail page too (`BookList.kt:88-99`).
    if (found.isEmpty && bookUrlPattern.isEmpty) {
      return _detailPageBooks(
        document,
        finalUrl,
        identityAddress: identityAddress,
        comparisonAddress: comparisonAddress,
        infoHtml: checked.body,
      );
    }
    final books = <HtmlBook>[];
    for (final entry in found) {
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
      final kind = await _kind(
        entry,
        search['kind'] ?? '',
        label: 'ruleSearch.kind',
      );
      final wordCount = await _optional(
        entry,
        search['wordCount'] ?? '',
        label: 'ruleSearch.wordCount',
      );
      final lastChapter = await _optional(
        entry,
        search['lastChapter'] ?? '',
        label: 'ruleSearch.lastChapter',
      );
      final intro = await _optional(
        entry,
        search['intro'] ?? '',
        label: 'ruleSearch.intro',
      );
      // Read this scalar field before parsing the returned address's existing
      // request options; interpolation and sibling JS keep AnalyzeRule order.
      final bookAddressValue = search['bookUrl']!.trim().isEmpty
          ? ''
          : '${await _field(entry, search['bookUrl']!, label: 'ruleSearch.bookUrl') ?? ''}';
      // The frozen `AnalyzeRule.getString(rule, isUrl = true)` answers the
      // analyser's base URL text for a Kotlin-blank result and keeps every other
      // finished scalar exactly as it was read (`AnalyzeRule.kt:315-323`).
      final bookAddress = sourceKotlinIsBlank(bookAddressValue)
          ? '$finalUrl'
          : bookAddressValue;
      late Uri preOptionUrl;
      late String expandedBookAddress;
      final (bookUrl, bookOptions) = await _request(
        checked.url,
        bookAddress,
        keyword,
        captureIdentity: (target, address) {
          preOptionUrl = target;
          expandedBookAddress = address;
        },
      );
      _bookRequests[bookUrl] = (
        address: bookAddress,
        base: finalUrl,
        options: bookOptions,
      );
      final nativeBookAddress = sourceUrlTextResolved(finalUrl, bookAddress);
      final publicationScalar = expandedBookAddress;
      final publicationParts = splitSourceUrlOptions(publicationScalar);
      final publicationAddress =
          '${sourceUrlTextResolved(finalUrl, publicationParts.path)}${publicationParts.tail}';
      books.add(
        HtmlBook(
          url: bookUrl,
          preOptionUrl: preOptionUrl,
          // Persist the single expansion's address, whose raw tail belongs
          // to the captured pre-option target rather than the wrapper source.
          rawAddress: expandedBookAddress,
          title: name,
          author: author,
          intro: formatSourceIntro(intro),
          lastChapter: lastChapter,
          wordCount: formatSourceWordCount(wordCount),
          kind: kind,
          infoHtml: nativeBookAddress == '$finalUrl' ? checked.body : null,
          addressContext: (
            comparisonAddress: nativeBookAddress,
            publicationAddress: publicationAddress,
          ),
        ),
      );
    }
    return books;
  }

  @override
  Future<SourceBookInfo> bookInfo(HtmlBook hit) async {
    _cancellation.throwIfCancelled();
    final retained = hit.infoHtml;
    final info = await _beginInformation(
      hit,
      evaluateHeaders: retained == null || retained.isEmpty,
    );
    return _fetchInformation(hit, info, retainedInfo: retained);
  }

  /// The information stage's pre-request setup, in the frozen composed order:
  /// source validation, the entity state the candidate carries, header
  /// evaluation, then the information rule group.
  Future<Map<String, String>> _beginInformation(
    HtmlBook hit, {
    bool evaluateHeaders = true,
  }) async {
    _book = hit;
    _chapter = null;
    _chapterTitle = null;
    _tocChapterAddress = null;
    // The candidate carries the variable text it was handed: a deferred
    // analysis reads and writes that text, never the stored row (#132). A
    // rebuilt TOC starts with no chapter variables of its own.
    final draft = _entityDraft;
    if (draft != null) {
      draft.resetBook(_sourceRef, hit.identityAddress);
      draft.seedBook(_sourceRef, hit.identityAddress, hit.variable);
    }
    _validate();
    _page = null;
    if (evaluateHeaders) {
      // This request's own source header, read before its address expands.
      _activeHeaders = await _readHeaders();
    }
    return _rules('ruleBookInfo', const []);
  }

  /// The information request, its check and its rules, over the setup a caller
  /// already ran.
  Future<SourceBookInfo> _fetchInformation(
    HtmlBook hit,
    Map<String, String> info, {
    String? retainedInfo,
  }) async {
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
    //
    // A fresh analysis has no request map (#136): the search hit's
    // [HtmlBook.identityAddress] is the resolved target its search recorded,
    // with the rule's raw option tail, so the details stage resolves that
    // target rather than re-resolving a relative rule text against [_base]. A
    // carrier without a recorded target keeps its raw text.
    final bookAddressText = bookRequest?.address ?? hit.identityAddress;
    final context = hit.addressContext;
    final String nativeBookAddress;
    if (context != null) {
      nativeBookAddress = context.comparisonAddress;
    } else if (bookRequest == null) {
      nativeBookAddress = hit.identityAddress;
    } else {
      nativeBookAddress = sourceUrlTextResolved(
        bookRequest.base,
        bookAddressText,
      );
    }
    final publicationAddress = context?.publicationAddress ?? nativeBookAddress;
    final cached = retainedInfo != null && retainedInfo.isNotEmpty;
    final (bookUrl, bookOptions) = cached
        ? (hit.url, bookRequest?.options ?? const SourceUrlOptions())
        : bookRequest == null
        ? await _request(_base, bookAddressText, '')
        : (hit.url, bookRequest.options);
    final bookInfo = retainedInfo != null && retainedInfo.isNotEmpty
        ? SourceStageResponse(body: retainedInfo, url: hit.url)
        : await _loginCheck(
            await _fetch(
              BookSourceStage.bookInfo,
              bookUrl,
              options: bookOptions,
              address: bookAddressText,
              base: bookRequest?.base ?? _base,
            ),
          );
    final document = _document(BookSourceStage.bookInfo, bookInfo);
    final retainedBody = retainedInfo != null && retainedInfo.isNotEmpty;
    final logicalBase = retainedBody
        ? _jsonNativeBaseUri(nativeBookAddress)
        : null;
    final parseBase = retainedBody ? (logicalBase ?? hit.url) : hit.url;
    final (book, tocAddress) = await _readBookInfo(
      document,
      hit,
      info,
      parseBase: parseBase,
      // The frozen `BookInfo.kt:137-145` cover call is the String-base overload
      // `NetworkUtils.getAbsoluteURL(redirectUrl, value)`, whose base is the
      // book's native logical text (`book.bookUrl`), not the expanded
      // publication; the overload builds its URL object before the base's first
      // comma (`NetworkUtils.kt:160-169`).
      coverRawBase: retainedBody ? nativeBookAddress : null,
    );
    final effectiveTocAddress = sourceKotlinIsBlank(tocAddress)
        ? ''
        : tocAddress;
    final Uri tocBase;
    if (retainedBody) {
      tocBase = logicalBase ?? bookInfo.url;
    } else {
      tocBase = hit.url.hasScheme ? bookInfo.url : hit.url;
    }
    final comparisonBase = retainedBody ? (logicalBase ?? tocBase) : tocBase;
    // The frozen `BookInfo.kt:150-157` compares the finished TOC text with the
    // book's own finished text: one native URL operation over the whole rule
    // result, not a resolution of its option-stripped path.
    final tocNativeText = effectiveTocAddress.isEmpty
        ? nativeBookAddress
        : sourceUrlNativeText(
            effectiveTocAddress,
            comparisonBase,
            rawBase: retainedBody ? nativeBookAddress : null,
          );
    return SourceBookInfo(
      book: book,
      tocAddress: effectiveTocAddress,
      bookUrl: bookUrl,
      bookOptions: bookOptions,
      bookAddress: publicationAddress,
      keyword: _keyword,
      page: _page,
      tocBase: tocBase,
      tocHtml: tocNativeText == nativeBookAddress ? bookInfo.body : null,
    );
  }

  @override
  Future<(HtmlBook, List<SourceChapter>)> tableOfContents(
    SourceBookInfo info,
  ) async {
    _cancellation.throwIfCancelled();
    _entityVariables.beginToc();
    // The information stage's book is the one this stage's rules and scripts
    // read (`book.*`), so a TOC run that follows another analysis still names
    // the book its own information result carries.
    _book = info.book;
    _chapter = null;
    _chapterTitle = null;
    _tocChapterAddress = null;
    // The TOC stage continues the information analysis it was handed, so its
    // rules see that analysis's own `key`/`page` bindings — not a later search
    // on this pipeline.
    _keyword = info.keyword;
    _page = info.page;
    final book = info.book;
    final bookUrl = info.bookUrl;
    final bookOptions = info.bookOptions;
    final bookAddressText = info.bookAddress;
    final toc = _rules('ruleToc', ['chapterList', 'chapterName', 'chapterUrl']);
    final retainedFirstPage = info.tocHtml != null && info.tocHtml!.isNotEmpty;
    // The non-empty body this analysis actually retained — the information
    // response the TOC stage reads instead of fetching a page. The frozen
    // content stage reuses exactly this body for a chapter whose own finished
    // text is the book's (`WebBook.kt:311-329`), so the fact is kept as the
    // response it is, never as a name or a marker.
    final retainedBody = retainedFirstPage ? info.tocHtml : null;
    // A retained page is read at the book's own finished native text
    // (`WebBook.kt:239-262` passes `book.tocUrl` as both base URLs), so its
    // next-page addresses resolve there rather than at the response URL a
    // redirect landed on. `book.bookUrl` is that native logical text, which the
    // frozen chapter constructor hands to the String overload
    // (`BookChapterList.kt:219-222` over `BookChapter.kt:143-149`), and that
    // overload builds its URL object from the text before its first comma
    // (`NetworkUtils.kt:160-169`). The expanded publication stays the ordinary
    // empty chapter's own fact below, not this base.
    final retainedLogicalText =
        info.book.addressContext?.comparisonAddress ??
        info.book.identityAddress;
    final retainedPageUrl = retainedFirstPage
        ? Uri.tryParse(retainedLogicalText)
        : null;
    final retainedChapterBase = retainedFirstPage
        ? Uri.tryParse(_sourceUrlStringBase(retainedLogicalText)) ??
              retainedPageUrl
        : null;
    // The complete `BookChapter.getAbsoluteURL()` text an ordinary empty chapter
    // of a retained page hands its content analysis (`BookChapter.kt:143-155`):
    // the book's own native text before its frozen option boundary, resolved
    // against this TOC analysis's own base, then that tail verbatim. A later page
    // therefore resolves against the whole native text, never against a bare
    // target and never against this page's response URL.
    final retainedEmptyFallbackText = retainedFirstPage
        ? _sourceAbsoluteText(
            retainedLogicalText,
            retainedChapterBase ?? retainedPageUrl ?? info.tocBase,
          )
        : null;
    if (!retainedFirstPage) {
      // This stage's first page is a request of its own: its source header is
      // read before that request's address options run.
      _activeHeaders = await _readHeaders();
      _cancellation.throwIfCancelled();
    }
    final (tocUrl, tocOptions) = retainedFirstPage
        ? (bookUrl, const SourceUrlOptions())
        : info.tocAddress.isEmpty
        ? (bookUrl, bookOptions)
        : await _request(info.tocBase, info.tocAddress, _keyword);
    final chapters = <SourceChapter>[];
    SourceStageResponse? finalTocResponse;
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

    /// The frozen `bookChapter.url = baseUrl` fallback (`BookChapterList.kt:229-243`)
    /// writes the page's own finished TOC text into an empty chapter URL. A
    /// retained first page publishes the approved TOC value; a fetched page
    /// resolves the address it was read for.
    String tocFallbackAddress(
      SourcePageRequest request, {
      bool retained = false,
    }) {
      if (retained) return info.tocUrl;
      if (request.address.isEmpty) {
        return resolveSourceTocUrl(
          address: '',
          base: request.url,
          fallbackAddress: bookAddressText,
        );
      }
      final parts = splitSourceUrlOptions(request.address);
      final address = Uri.parse(parts.path);
      if (address.hasScheme) {
        return request.address;
      }
      return '${sourceUrlTextResolved(request.base, parts.path)}${parts.tail}';
    }

    /// This analysis's retained page as one chapter's first content response, or
    /// null when the frozen reuse condition does not hold for the chapter that
    /// [chapterText] is.
    ///
    /// The condition is two finished native texts and one actual response: the
    /// chapter's own native text, the book's own native text, and the body this
    /// analysis really retained. A chapter text that merely *resolves* to the
    /// book's address is a different text and is fetched — nothing here parses
    /// the address to compare it, and this adapter's expanded publication never
    /// decides reuse. [absoluteText] is that chapter's complete
    /// `BookChapter.getAbsoluteURL()` text (`WebBook.kt:311-329`), the chapter
    /// text itself by default: it becomes the retained page's base exactly as the
    /// frozen branch hands it to its analysis, so a tail's own `..` segments take
    /// part in a later page's resolution.
    SourceStageResponse? retainedChapterPage(
      String chapterText,
      Uri target, {
      String? absoluteText,
    }) {
      final body = retainedBody;
      if (body == null || chapterText != retainedLogicalText) return null;
      return SourceStageResponse(
        body: body,
        url: Uri.tryParse(absoluteText ?? chapterText) ?? target,
      );
    }

    await walkSourcePages(
      first: (
        url: tocUrl,
        options: tocOptions,
        address: info.tocAddress,
        base: info.tocBase,
      ),
      // The TOC follows next-page declarations without a count bound
      // (`BookChapterList.kt:48-86`); repeated URLs still fail by name.
      maxPages: null,
      cycleError: 'TOC page cycle',
      // The frozen drops an item equal to the page it was read from
      // (`BookChapterList.kt:96-100`).
      dropSelf: true,
      // A declared next-page address costs nothing here but the identity the
      // walk's own duplicate check needs: the frozen `NetworkUtils.getAbsoluteURL`
      // builds no `AnalyzeUrl`, so no source header is read and nothing the text
      // declares runs for an address the walk discards. The page itself is
      // analysed in its own visit.
      resolve: (address, pageUrl) async => (
        url: _declaredPageUrl(pageUrl, address),
        options: const SourceUrlOptions(),
      ),
      visit: (request, {required readNext}) async {
        clearTocChapter();
        try {
          final isFirstPage = firstPage;
          final cachedFirstPage =
              isFirstPage &&
              info.tocHtml != null &&
              info.tocHtml!.isNotEmpty &&
              request.url == info.bookUrl;
          // The stage's first page was analysed before the walk and sends that
          // analysis; a declared page the walk really reaches is a request of
          // its own, analysed here on the header it reads first.
          final (pageUrl, pageOptions) = isFirstPage
              ? (request.url, request.options)
              : await _analyzeDeclaredPage(request);
          var tocPage = cachedFirstPage
              ? SourceStageResponse(
                  body: info.tocHtml!,
                  url: retainedPageUrl ?? info.tocBase,
                )
              : await _fetch(
                  BookSourceStage.tableOfContents,
                  pageUrl,
                  options: pageOptions,
                  address: request.address,
                  base: request.base,
                );
          // The frozen TOC stage checks login once, on its first response
          // (`WebBook.kt:253`); the `nextTocUrl` pages never run the check. A
          // retained same-page body has no request/check/header work to repeat.
          if (isFirstPage) {
            if (!cachedFirstPage) tocPage = await _loginCheck(tocPage);
            firstPage = false;
          }
          finalTocResponse = tocPage;
          final document = _document(BookSourceStage.tableOfContents, tocPage);
          final entries = await _elementList(
            document,
            toc['chapterList']!,
            label: 'ruleToc.chapterList',
          );
          // The declared-list walk skips this getter; otherwise it completes
          // after list acquisition and before item reads (BookChapterList:187-207).
          final nextRule = readNext ? toc['nextTocUrl'] : null;
          final nextTexts = nextRule == null
              ? const <String>[]
              : await _pageTexts(
                  document,
                  nextRule,
                  label: 'ruleToc.nextTocUrl',
                );
          // Only ordinary empty URLs need this text; cache it lazily per page.
          late final ordinaryFallbackAddress = tocFallbackAddress(
            request,
            retained: cachedFirstPage,
          );
          for (var index = 0; index < entries.length; index++) {
            publishTocChapter('', '');
            // One rebuilt item's chapter variables start empty and keep only
            // what this item's own rules write (#132).
            _entityVariables.beginChapter();
            try {
              final entry = entries[index];
              // The frozen adds a chapter only when its title is non-empty
              // (`BookChapterList.kt:244`), so an element the name rule matched nothing
              // on is skipped instead of failing the whole TOC.
              final name = await _optional(
                entry,
                toc['chapterName']!,
                label: 'ruleToc.chapterName',
              );
              publishTocChapter(name, '');
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
              publishTocChapter(name, chapterUrl);
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
              // Tag/volume observe the raw address; VIP/pay observe its fallback.
              publishTocChapter(
                name,
                chapterUrl.isEmpty
                    ? (isVolume ? '$name$index' : ordinaryFallbackAddress)
                    : chapterUrl,
              );
              if (name.isEmpty) continue;
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
              final SourceChapter chapter;
              if (chapterUrl.isEmpty) {
                // The frozen's empty-URL fallbacks (`BookChapterList.kt:229-243`): a
                // volume takes the identity text `title + index`, every other chapter
                // takes the TOC page's own address, which resolves to the page it was
                // read from.
                if (isVolume) {
                  chapter = SourceChapter.volume(
                    name,
                    index,
                    tocUrl: tocPage.url,
                    tag: tag,
                    isVip: isVip,
                    isPay: isPay,
                  );
                } else {
                  final target =
                      // Only a retained page's own address stands in for the
                      // chapter text; a fetched TOC page keeps its actual
                      // response target.
                      cachedFirstPage
                      ? _ordinaryChapterTarget(
                          ordinaryFallbackAddress,
                          tocPage.url,
                        )
                      : tocPage.url;
                  // The frozen empty-URL fallback writes this TOC page's own
                  // finished address into the chapter (`BookChapterList.kt:229-243`).
                  // On a retained page that text is the book's own native text
                  // (`BookInfo.kt:150-153`), never this adapter's expanded
                  // publication; a later fetched page keeps its own completed
                  // address, so its ordinary empty chapter never reuses the first
                  // page's retained body.
                  final fallbackText = cachedFirstPage
                      ? retainedEmptyFallbackText
                      : ordinaryFallbackAddress;
                  final retainedPage = fallbackText == null
                      ? null
                      : retainedChapterPage(
                          cachedFirstPage
                              ? retainedLogicalText
                              : ordinaryFallbackAddress,
                          target,
                          absoluteText: fallbackText,
                        );
                  chapter = SourceChapter(
                    name,
                    target,
                    rawAddress: ordinaryFallbackAddress,
                    tag: tag,
                    isVip: isVip,
                    isPay: isPay,
                    // A reused page fetches nothing, and what it would have
                    // fetched is this fallback text: the approved payload keeps
                    // the request input and the published identity apart, so
                    // `requestAddress` — and with it `persistedAddress` — is that
                    // complete native text, while the target, key and progress
                    // identity stay the published ones. The text is kept as the
                    // rule wrote it: building a carrier reads no option object, so
                    // a family this analysis cannot consume stays the request's
                    // own refusal.
                    fetchContext: fallbackText == null || retainedPage == null
                        ? null
                        : (
                            requestAddress: fallbackText,
                            retainedPage: retainedPage,
                          ),
                  );
                }
              } else {
                // The chapter keeps its rule's finished text, and the request it
                // will make is that same text: a `{{…}}` template or an `@js:`
                // program it carries belongs to that request, so building this
                // chapter runs neither. The key names the pending address
                // resolved against this TOC page's own base, and the option tail
                // stays verbatim behind it.
                final chapterBase = cachedFirstPage
                    ? (retainedChapterBase ?? tocPage.url)
                    : tocPage.url;
                final pending = _pendingChapterAddress(chapterBase, chapterUrl);
                chapter = SourceChapter(
                  name,
                  pending.target,
                  rawAddress: chapterUrl,
                  addressBase: chapterBase,
                  tag: tag,
                  isVolume: isVolume,
                  isVip: isVip,
                  isPay: isPay,
                  fetchContext: (
                    requestAddress: pending.text,
                    // Only an equal finished native text reuses this analysis's
                    // retained page; a relative text that merely resolves to
                    // the book's address carries its own request instead
                    // (`WebBook.kt:311-329`). The chapter's complete native
                    // absolute text is its own pending request text.
                    retainedPage: retainedChapterPage(
                      chapterUrl,
                      pending.target,
                      absoluteText: pending.text,
                    ),
                  ),
                );
              }
              // The chapter's own variable text, read after the item's own rule
              // analysis: the item's rule scripts write it now (#132), and a
              // supported `chapterUrl` option `js` writes it later, when the
              // actual content request runs that address (`chapter`). Reading
              // here runs no option script.
              final chapterVariable = _entityVariables.chapterText;
              // A repeated chapter address is kept, as this path always has: the frozen
              // deduplicates its list by URL (`BookChapterList.kt:123`) and the HTML
              // path refuses the repeat by name, but a JSON TOC that names one address
              // twice has always produced both chapters here. Such a pair would name one
              // row twice, which is a store-level limit (D4), not a rule decision taken
              // at this point.
              chapters.add(chapter.withVariable(chapterVariable));
              _entityVariables.recordTocChapter();
            } finally {
              _entityVariables.endChapter();
              clearTocChapter();
            }
          }
          return (pageUrl: tocPage.url, items: nextTexts);
        } finally {
          clearTocChapter();
        }
      },
    );
    if (chapters.isEmpty) {
      throw SourceStageDiagnostic.response(
        stage: BookSourceStage.tableOfContents,
        url: finalTocResponse?.url ?? tocUrl,
        body: finalTocResponse?.body ?? '',
        httpResponse: finalTocResponse?.httpResponse,
      );
    }
    final rows = await _hostSurface.chapterRestorationRows(
      _sourceRef,
      book.identityAddress,
    );
    final old = {for (final row in rows) (row.index, row.title): row.variable};
    final restored = [
      for (var i = 0; i < chapters.length; i++)
        if (old[(i, chapters[i].name)] case final String variable)
          chapters[i].withVariable(variable)
        else
          chapters[i],
    ];
    final bookVariable = await _entityVariables.bookVariable(
      _sourceRef,
      book.identityAddress,
    );
    final handoff = await _entityVariables.prepareTocHandoff([
      for (var i = 0; i < chapters.length; i++) old[(i, chapters[i].name)],
    ]);
    _cancellation.throwIfCancelled();
    _entityVariables.publishTocHandoff(handoff);
    return (book.withVariable(bookVariable), restored);
  }

  /// The composed entry validates the TOC group before its first request, as it
  /// always has: a `ruleToc` field that belongs to another stage is refused by
  /// name before any information request, so the composed failure order is the
  /// one current callers already see. Each stage entry validates its own group
  /// when it runs.
  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async {
    // The composed entry keeps the order current callers already see: source
    // validation, entity state, header evaluation and the information rule
    // group first, then the TOC rule group, all before any request. A bad
    // source, header or information rule is never replaced by a later TOC
    // group error.
    final retained = hit.infoHtml;
    final info = await _beginInformation(
      hit,
      evaluateHeaders: retained == null || retained.isEmpty,
    );
    _rules('ruleToc', ['chapterList', 'chapterName', 'chapterUrl']);
    return tableOfContents(
      await _fetchInformation(hit, info, retainedInfo: retained),
    );
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
    Uri finalUrl, {
    required String identityAddress,
    required String comparisonAddress,
    required String infoHtml,
  }) async {
    final infoRules = source['ruleBookInfo'];
    final nameRule = infoRules is Map ? infoRules['name'] : null;
    if (nameRule == null || nameRule == '') {
      return const <HtmlBook>[];
    }
    final (book, _) = await _readBookInfo(
      document,
      HtmlBook(
        url: finalUrl,
        rawAddress: identityAddress,
        title: '',
        infoHtml: infoHtml,
        addressContext: (
          comparisonAddress: comparisonAddress,
          publicationAddress: identityAddress,
        ),
      ),
      _rules('ruleBookInfo', const []),
    );
    if (book.title.isEmpty) return const <HtmlBook>[];
    // The response's own final book-variable text rides the carrier: a
    // search-only rule write survives into the deferred details pipeline the
    // association opens next (#132).
    return <HtmlBook>[
      book.withVariable(
        await _entityVariables.bookVariable(_sourceRef, book.identityAddress),
      ),
    ];
  }

  /// `ruleBookInfo` over one response document this pipeline already has.
  ///
  /// [details] decodes its response and consumes the completed TOC address;
  /// the search fallback completes that getter too, without fetching it.
  /// The search stage calls it for a response whose final URL
  /// matched `bookUrlPattern` (`BookList.kt:53-70`) or for the
  /// empty-element-list fallback (`BookList.kt:91`), where the frozen
  /// `getInfoItem` runs the same rules over the response it has.
  ///
  /// [hit] is the book the rules start from. A search synthesizes an empty one,
  /// so the detail page's own name and author are taken, exactly as the frozen
  /// empty `Book` takes them (`BookInfo.kt:60-73`).
  Future<(HtmlBook, String)> _readBookInfo(
    Object? document,
    HtmlBook hit,
    Map<String, String> info, {
    Uri? parseBase,
    String? coverRawBase,
  }) async {
    _book = hit;
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
    if (!(identical(page, _nativeObjectRoot) && page is Map)) {
      final raw = source['ruleBookInfo'] as Map;
      for (final entry in info.entries) {
        final extraction = RuleField.extractionText(entry.value);
        if (extraction != null &&
            _deferBookInfoKey(raw, entry.key, extraction)) {
          try {
            JsonSourceRules.validate(extraction);
          } on UnsupportedError catch (error) {
            throw UnsupportedError('ruleBookInfo.${entry.key}: $error');
          }
        }
      }
    }
    final canReName = info['canReName']?.trim().isNotEmpty == true;
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
        // A metadata copy does not clear the variable or retained search
        // response it started from (#132, retained-body handoff).
        variable: current.variable,
        infoHtml: current.infoHtml,
        addressContext: current.addressContext,
      );
    }

    final infoTitle = await _optional(
      page,
      info['name'] ?? '',
      label: 'ruleBookInfo.name',
    );
    final mergedTitle = infoTitle.isNotEmpty && (canReName || hit.title.isEmpty)
        ? infoTitle
        : hit.title;
    publishBook(title: mergedTitle);
    final infoAuthor = await _optional(
      page,
      info['author'] ?? '',
      label: 'ruleBookInfo.author',
    );
    final mergedAuthor =
        infoAuthor.isNotEmpty && (canReName || hit.author.isEmpty)
        ? infoAuthor
        : hit.author;
    publishBook(author: mergedAuthor);
    final infoKind = await _kind(
      page,
      info['kind'] ?? '',
      label: 'ruleBookInfo.kind',
    );
    publishBook(kind: infoKind);
    final infoWordCount = formatSourceWordCount(
      await _optional(
        page,
        info['wordCount'] ?? '',
        label: 'ruleBookInfo.wordCount',
      ),
    );
    publishBook(wordCount: infoWordCount);
    final infoLastChapter = await _optional(
      page,
      info['lastChapter'] ?? '',
      label: 'ruleBookInfo.lastChapter',
    );
    publishBook(lastChapter: infoLastChapter);
    final infoIntro = formatSourceIntro(
      await _optional(page, info['intro'] ?? '', label: 'ruleBookInfo.intro'),
    );
    publishBook(intro: infoIntro);
    final cover = await _optional(
      page,
      info['coverUrl'] ?? '',
      label: 'ruleBookInfo.coverUrl',
    );
    // The frozen `BookInfo.kt:137-145` cover call is the String-base overload
    // `NetworkUtils.getAbsoluteURL(redirectUrl, value)`, so a retained response
    // resolves against the book's raw logical text and a fetched one against the
    // response URL it actually came from.
    publishBook(
      cover: cover.isEmpty
          ? ''
          : coverRawBase == null
          ? '${_url(parseBase ?? hit.url, cover)}'
          : sourceUrlTextResolved(
              parseBase ?? hit.url,
              cover,
              rawBase: _sourceUrlStringBase(coverRawBase),
            ),
    );
    final book = _book!;
    final tocAddress = await _optional(
      page,
      info['tocUrl'] ?? '',
      label: 'ruleBookInfo.tocUrl',
    );
    return (book, tocAddress);
  }

  /// `ruleContent`: one chapter's text.
  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    if (book != null) _book = book;
    _tocChapterAddress = null;
    _chapter = chapter;
    // A deferred content analysis starts from the carriers it was handed: the
    // book's variable text and this chapter's own, keyed as the content stage's
    // `book.bookUrl`/`chapter.url` bind them (#132).
    final candidateBook = _book;
    if (candidateBook != null) {
      _entityDraft?.seedBook(
        _sourceRef,
        candidateBook.identityAddress,
        candidateBook.variable,
      );
      _entityDraft?.seedChapter(
        _sourceRef,
        candidateBook.identityAddress,
        chapter.storeKey,
        chapter.variable,
      );
      // The ordinary path reads and writes the space's rows, keyed by the
      // chapter's row identity. A chapter whose key holds no entry at all
      // starts from its own carrier text: a TOC write lands under the TOC
      // stage's own key, so the rules and the final snapshot must still see it.
      // A stored row — or an unwritten entry, even one whose text is null — is
      // present and authoritative and is never reseeded (#132).
      if (_entityDraft == null && chapter.variable != null) {
        final chapterKey = chapter.storeKey;
        final entry = await _hostSurface.chapterVariableRow(
          _sourceRef,
          candidateBook.identityAddress,
          chapterKey,
        );
        if (entry == null) {
          await _hostSurface.putChapterVariable(
            _sourceRef,
            candidateBook.identityAddress,
            chapterKey,
            chapter.variable,
          );
        }
      }
    }
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
    final contentBookKey = _book?.identityAddress;
    if (chapter.rendersTagAsContent) {
      // The volume shortcut makes no request and runs no rule, but the
      // caller still gets the carriers' entity snapshots (#132).
      return HtmlChapterBody(
        chapter.tag ?? '',
        0,
        bookVariable: contentBookKey == null
            ? null
            : await _entityVariables.bookVariable(_sourceRef, contentBookKey),
        chapterVariable: await _entityVariables.chapterVariable(
          _sourceRef,
          contentBookKey ?? '',
          chapter.storeKey,
        ),
      );
    }
    final parts = <String>[];
    String? contentTitle;
    // The selected content stage reads `ruleContent.title` after it has joined
    // every page, against the first response's document (`BookContent.kt:65-69`,
    // `:169-182`). The first post-login document and its raw body are retained
    // for that later read; the page walk itself never reads them.
    Object? firstPageDocument;
    String? firstPageBody;
    var firstPage = true;
    // The complete native raw base of a retained first page, while that page's
    // own declared addresses are resolved. Its later page's own response base
    // takes over as soon as a real page is fetched.
    String? contentRawBase;
    // The frozen page walk (`BookContent.kt:54-135`), the same one the HTML
    // adapter runs: this page, then the pages its `nextContentUrl` list declares.
    //
    // A real first content request analyses its complete input: a generated
    // chapter's pending text or the address a stored/imported chapter carries.
    // Templates and request options run for this request, keeping the chapter's
    // identity and saved input independent of the selected network target.
    //
    // A context that also carries a retained page is the frozen content-reuse
    // branch (`WebBook.kt:311-329`): the response the TOC stage already read is
    // this chapter's first content page, so it runs no request analysis, reads
    // no source header, sends nothing and runs no login check. The pages that
    // first one declares are real requests again.
    final chapterContext = chapter.fetchContext;
    final retainedPage = chapterContext?.retainedPage;
    final chapterBase = chapter.addressBase ?? chapter.url;
    if (retainedPage == null) {
      // This request's own source header, read before its own address options
      // run. The reuse branch reuses the response the TOC stage already read, so
      // it reads none and sends nothing.
      _activeHeaders = await _readHeaders();
    }
    final (firstUrl, firstOptions) = retainedPage != null
        ? (chapter.url, const SourceUrlOptions())
        : await _request(
            chapterBase,
            chapterContext?.requestAddress ?? chapter.address,
            _keyword,
          );
    final pages = await walkSourcePages(
      first: (
        url: firstUrl,
        options: firstOptions,
        address: chapterContext?.requestAddress ?? chapter.address,
        base: chapterBase,
      ),
      // The frozen content walk has no page-count bound either
      // (`BookContent.kt:54-135`): an empty declaration or the next chapter's own
      // address ends it, and a repeated URL still fails by name.
      maxPages: null,
      cycleError: 'Content page cycle',
      // The frozen stops the one-URL walk before fetching the next chapter's
      // own URL (`BookContent.kt:85-88`); the declared-list walk has no guard.
      nextChapterUrl: nextChapterUrl == null || nextChapterUrl.isEmpty
          ? null
          : SourceHttpUri.parse(nextChapterUrl),
      // A declared next-page address costs nothing here but the identity the
      // walk's own duplicate check needs: the frozen `NetworkUtils.getAbsoluteURL`
      // builds no `AnalyzeUrl`, so no source header is read and nothing the text
      // declares runs for an alias the walk discards. The page itself is
      // analysed in its own visit, against the complete native base the page
      // that declared it carried.
      resolve: (address, pageUrl) async => (
        url: _declaredPageUrl(pageUrl, address, rawBase: contentRawBase),
        options: const SourceUrlOptions(),
      ),
      visit: (request, {required readNext}) async {
        final isFirstPage = firstPage;
        final retainedFirst = isFirstPage ? retainedPage : null;
        // The complete native base this page's own text resolves against, read
        // before this visit names what its declared addresses get.
        final pageRawBase = contentRawBase;
        contentRawBase = retainedFirst == null
            ? null
            : chapterContext?.requestAddress;
        // The first real page was analysed above and keeps that analysis; a
        // real next page is a request of its own, analysed here on the source
        // header it reads first.
        final (pageUrl, pageOptions) = retainedFirst != null
            ? (request.url, const SourceUrlOptions())
            : isFirstPage
            ? (request.url, request.options)
            : await _analyzeDeclaredPage(request, rawBase: pageRawBase);
        var contentPage =
            retainedFirst ??
            await _fetch(
              BookSourceStage.content,
              pageUrl,
              options: pageOptions,
              address: request.address,
              base: request.base,
            );
        // The frozen content stage checks login once, on its first response
        // (`WebBook.kt:336`); the `nextContentUrl` pages never run it. A retained
        // first page made no request of this stage for a check to read.
        if (isFirstPage) {
          if (retainedFirst == null) {
            contentPage = await _loginCheck(contentPage);
          }
          firstPage = false;
        }
        final document = _document(BookSourceStage.content, contentPage);
        if (parts.isEmpty) {
          firstPageDocument = document;
          firstPageBody = contentPage.body;
        }
        // The frozen content stage turns one page's value into text here, before
        // the pages are joined (`BookContent.kt:178-181`) — the same pass the HTML
        // adapter runs, `formatKeepImg` then the `&`-guarded `unescapeHtml4`,
        // because the frozen stage is adapter-agnostic.
        parts.add(
          formatContentPage(
            await _text(
              document,
              content['content']!,
              label: 'ruleContent.content',
              unescape: false,
              response: contentPage,
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
    // The selected title read is after the joined body, so the source state the
    // content scripts wrote is visible and those scripts saw the incoming
    // chapter title. Its document is the first post-login response, not the last
    // page's; restoring it makes the reader's own content context the one the
    // title rule reads (`BookContent.kt:65-69`, `:169-182`).
    final titleRule = content['title'];
    final firstDocument = firstPageDocument;
    if (titleRule != null && firstDocument != null) {
      _responseRoot = firstDocument;
      _responseText = firstPageBody;
      final title = await _optional(
        firstDocument,
        titleRule,
        label: 'ruleContent.title',
      );
      if (title.trim().isNotEmpty) {
        contentTitle = _chapterTitle = title;
        _chapter = SourceChapter(
          title,
          chapter.url,
          rawAddress: chapter.rawAddress,
          storedKey: chapter.storedKey,
          addressBase: chapter.addressBase,
          variable: chapter.variable,
          fetchContext: chapter.fetchContext,
        );
      }
    }
    return HtmlChapterBody(
      text,
      pages,
      title: contentTitle,
      images: extractChapterImages(text),
      // The final entity snapshots of this content request, pagination and all:
      // every page wrote through the same candidate draft (#132).
      bookVariable: contentBookKey == null
          ? null
          : await _entityVariables.bookVariable(_sourceRef, contentBookKey),
      chapterVariable: await _entityVariables.chapterVariable(
        _sourceRef,
        contentBookKey ?? '',
        chapter.storeKey,
      ),
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
        .get('$target', headers: await _readHeaders(), readBytes: true);
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
    if (field.isLiteralValue) {
      return sourceScriptTexts(
        await field.apply(
          document,
          forValue: true,
          forStringList: true,
          contentText: _analysisText(document),
        ),
      );
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
/// [url] is the resolved target before request-option execution, without the
/// option tail: a newly generated chapter keys by its rule's own address
/// resolved, while the options its request applies belong to that request
/// ([fetchContext]). [rawAddress] is the address text the TOC rule produced,
/// options included — the frozen `BookChapter.url` (`BookChapterList.kt:222`) —
/// so the request that fetches the chapter can parse its options the way the
/// frozen `AnalyzeUrl` does (`AnalyzeUrl.kt:214-222`).
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
    this.variable,
    this.fetchContext,
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
    String? variable,
  }) => SourceChapter(
    title,
    tocUrl,
    rawAddress: '$title$index',
    tag: tag,
    isVolume: true,
    isVip: isVip,
    isPay: isPay,
    variable: variable,
  );

  /// Rebuilds a stored address. Imported relative addresses resolve against
  /// their owning book at fetch time; the raw address remains the store's key.
  ///
  /// A saved `{{…}}` template or `@js:` program is pending text rather than a
  /// URI: it resolves against the book as text alone, so rebuilding it runs
  /// nothing and never reads the program's `@js:` as a scheme.
  factory SourceChapter.fromAddress(
    String name,
    String address, {
    Uri? bookUrl,
    String? chapterKey,
    String? tag,
    bool isVolume = false,
    bool isVip = false,
    bool isPay = false,
    String? variable,
  }) {
    final target = sourceUrlTargetOf(address);
    final base = bookUrl;
    final Uri url;
    if (base == null) {
      url = SourceHttpUri.parse(target);
    } else if (_isPendingAddressText(address)) {
      url = JsonSourcePipeline._pendingChapterAddress(base, address).target;
    } else {
      url = SourceHttpUri.parse('${base.resolve(target)}');
    }
    return SourceChapter(
      name,
      url,
      rawAddress: address,
      storedKey: chapterKey,
      addressBase: bookUrl,
      tag: tag,
      isVolume: isVolume,
      isVip: isVip,
      isPay: isPay,
      variable: variable,
    );
  }

  final String name;
  final Uri url;

  /// The rule's own address text, or null when the caller only has a URL.
  final String? rawAddress;

  /// Existing store identity; new TOC chapters still key by their resolved URL.
  final String? storedKey;

  /// The `ruleToc.updateTime` value (the frozen `BookChapter.tag`). A parsed
  /// rule result is retained exactly, including the empty string; null remains
  /// the manual/imported default when this carrier has no parsed value.
  final String? tag;

  /// A volume heading rather than a readable chapter (`ruleToc.isVolume`).
  final bool isVolume;

  /// A chapter the source marks as VIP (`ruleToc.isVip`).
  final bool isVip;

  /// A chapter the source marks as already paid for (`ruleToc.isPay`).
  final bool isPay;

  /// The chapter row's own variable text (the frozen `BookChapter.variable`
  /// column, `BookChapter.kt:58`), or null when this carrier carries none.
  ///
  /// A carrier keeps the text so an analysis can seed a candidate from it and
  /// hand the final text on with the same identity; the runtime reads and
  /// writes the row (or the candidate draft) under the key the script sees as
  /// `chapter.url`, never this field directly.
  final String? variable;

  /// Input for a generated chapter's content request and, when eligible, its
  /// retained first response.
  ///
  /// The complete request text stays independent of [url] and the target
  /// selected by request options. [persistedAddress] saves that text, including
  /// its original query and exact option tail. The record and retained response
  /// stay in memory; a chapter rebuilt from stored text or an import has none.
  final ({String requestAddress, SourceStageResponse? retainedPage})?
  fetchContext;

  /// This carrier with [variable] replaced, every identity, address and marker
  /// field retained. A metadata or content-stage copy must not drop the
  /// variable it started from.
  SourceChapter withVariable(String? variable) => SourceChapter(
    name,
    url,
    rawAddress: rawAddress,
    storedKey: storedKey,
    addressBase: addressBase,
    tag: tag,
    isVolume: isVolume,
    isVip: isVip,
    isPay: isPay,
    variable: variable,
    fetchContext: fetchContext,
  );

  /// The key a TOC write keeps for this chapter (D4). A chapter keys by its
  /// resolved target, except a volume the rules left without a URL: it has no
  /// page, so the frozen identity text is what the row keeps and what tells it
  /// apart from its siblings on the same TOC page.
  String get storeKey => rendersTagAsContent ? address : '$url';

  String get progressKey => storedKey ?? storeKey;

  /// Base used to reanalyse a stored address via `java.initUrl()`.
  final Uri? addressBase;

  /// The rule's own address text when it was kept. A bare URL carries no
  /// options, so it parses to itself. A chapter that carries [fetchContext]
  /// fetches its complete pending request text instead.
  String get address => rawAddress ?? '$url';

  /// The options this chapter's own request applies. Parsed where the chapter
  /// is fetched, not where the TOC was read, which is what keeps them across a
  /// restart once the address text is what the store holds.
  SourceUrlOptions get options => splitSourceUrlOptions(address).options;

  /// The address text to persist: the target before request-option execution,
  /// resolved, with the exact option tail kept verbatim.
  ///
  /// A chapter that carries [fetchContext] keeps exactly its
  /// `fetchContext.requestAddress`, which is that complete text: the key stays
  /// the bare target while the row keeps the options the content stage
  /// reanalyses. Every other chapter keeps the tail behind [url].
  ///
  /// A stored row has no TOC page left to resolve a relative address against, so
  /// the target is written absolute. The frozen stores the rule's own text and
  /// resolves it against the book's URL when it fetches the chapter; the options
  /// and the URL a request targets are the same either way, and a row written by
  /// [SourceChapter.fromAddress] keeps parsing to itself.
  ///
  /// A stored `{{…}}` template or `@js:` program is the exception: that text is
  /// pending analysis, so the row keeps it exactly as it was saved. Re-deriving
  /// it from [url] would re-encode its braces and pipes and lose the form the
  /// request has to analyse.
  ///
  /// A volume the rules left without a URL has no target to write absolute
  /// (`rendersTagAsContent`): the frozen keeps the identity text
  /// `title + index` as that chapter's whole state, so the row keeps it too and
  /// the shortcut reads it again after a restart.
  String get persistedAddress {
    if (rendersTagAsContent) return address;
    final context = fetchContext;
    if (context != null) return context.requestAddress;
    if (_isPendingAddressText(address)) return address;
    return '$url${sourceUrlOptionTailOf(address)}';
  }

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

/// The book's own finished comparison text as a base URL.
///
/// The frozen retained `WebBook` hands `book.bookUrl` to `BookInfo` and
/// `AnalyzeRule.setRedirectUrl` only constructs a URL from it: no `AnalyzeUrl`
/// and no request option object is created there, so the comparison text's own
/// `,{…}` boundary is a text boundary alone. A boundary a legal header value left
/// in the finished text is data; the request parsers and `SourceChapter.options`
/// keep their named refusal of an unsupported family.
Uri? _jsonNativeBaseUri(String text) {
  final value = text.trim();
  if (value.startsWith('@js:') ||
      value.toLowerCase().startsWith('<js>') ||
      value.startsWith('[') ||
      value.startsWith('{')) {
    return Uri.tryParse(value);
  }
  final boundary = sourceUrlOptionBoundaryOf(value);
  return Uri.tryParse(
    boundary == null ? value : value.substring(0, boundary).trim(),
  );
}
