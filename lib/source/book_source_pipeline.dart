import 'dart:typed_data';

import '../domain/contracts.dart';
import 'book_source_service.dart';
import 'html4_unescape.dart';
import 'html_source_pipeline.dart';
import 'json_source_pipeline.dart';
import 'js_source_runtime.dart' show SourceHostMessage, SourceStageResponse;
import 'source_host_state.dart';
import 'source_url_rules.dart';

/// The shapes the pages hold come with the interface, so a caller that runs a
/// source needs one import for them: [HtmlBook] and [HtmlChapterBody] from the
/// HTML adapter's file, [SourceChapter] from the JSON adapter's.
export 'html_source_pipeline.dart'
    show HtmlBook, HtmlChapterBody, SourceChapterImage, extractChapterImages;
export 'json_source_pipeline.dart' show SourceChapter;

/// Fetches the first actual content response and runs its login hook once.
/// Only diagnosed transport failures get the synthetic Legado error response;
/// an ordinary HTTP response follows the normal check path, even if it is 500.
Future<SourceStageResponse> fetchContentWithLoginCheck({
  required Uri url,
  required Future<SourceStageResponse> Function() fetch,
  required Future<SourceStageResponse> Function(SourceStageResponse) check,
  required SourceCancellation cancellation,
}) async {
  final SourceStageResponse response;
  try {
    response = await fetch();
  } on SourceStageDiagnostic catch (failure) {
    final body = switch (failure.kind) {
      SourceStageFailureKind.connection => 'connection',
      SourceStageFailureKind.timeout => 'timeout',
      _ => null,
    };
    if (body == null) rethrow;
    cancellation.throwIfCancelled();
    SourceStageResponse? recovered;
    try {
      recovered = await check(
        SourceStageResponse(body: body, url: url, statusCode: 500),
      );
    } on SourceRequestCancelled {
      rethrow;
    } on Exception {
      // Recovery failure leaves the original request diagnostic authoritative.
    } on UnsupportedError {
      // A named refusal during recovery also leaves the original failure intact.
    }
    cancellation.throwIfCancelled();
    if (recovered != null && recovered.statusCode != 500) return recovered;
    rethrow;
  }
  return check(response);
}

/// The frozen source's check keyword (`BookSource.getCheckKeyword`).
///
/// See `BookSource.kt:208-215` in Legado baseline `14dd24945`: a nonblank
/// `ruleSearch.checkKeyWord` wins without trimming the value; otherwise the
/// caller's fallback is used. The field is a *check* keyword — the frozen
/// readers of it are the source check and the debug page's search box — so the
/// normal search path does not read it (`HtmlSourcePipeline.search`).
///
/// The frozen app reads the field through Gson into `String?`, whose string
/// adapter turns a scalar token into its text and rejects an array or object
/// while the source is parsed, so a numeric or boolean value is a keyword here
/// rather than a malformed rule; only a structured value is refused.
String sourceCheckKeyword(Map<String, dynamic> source, String fallback) {
  final search = source['ruleSearch'];
  final value = search is Map ? search['checkKeyWord'] : null;
  if (value == null) return fallback;
  final String text;
  if (value is String) {
    text = value;
  } else if (value is num || value is bool) {
    text = '$value';
  } else {
    throw const FormatException('ruleSearch.checkKeyWord 必须是字符串规则');
  }
  return text.trim().isNotEmpty ? text : fallback;
}

/// Frozen `String?.isTrue()` (`StringExtensions.kt:74-79`): null, a blank value
/// and the literal `null` are false, a value that trims to `false`, `no`, `not`
/// or `0` (case-insensitively) is false, and every other value — `true`,
/// `TRUE`, `1`, `是`, any other text — is true. The `ruleToc.isVolume`/`isVip`/
/// `isPay` markers are read through it.
///
/// Blank and trim are the Kotlin `Char.isWhitespace()` definition
/// ([sourceKotlinIsBlank], [sourceKotlinTrim]); Dart's own `trim()` is the other
/// way round on `0x85` and `0x1C`–`0x1F`.
bool sourceIsTrue(String? value) {
  if (value == null || sourceKotlinIsBlank(value) || value == 'null') {
    return false;
  }
  return !RegExp(
    r'^(false|no|not|0)$',
    caseSensitive: false,
  ).hasMatch(sourceKotlinTrim(value));
}

// Frozen AppPattern.wordCountRegex; Android Pattern's \s uses White_Space.
final _tocWordCountToken = RegExp(
  r'(?:^|字数[：:、]?|\p{White_Space}+)[0-9万千百.]{1,6}字',
  unicode: true,
);

/// The visible `BookChapter.tag` in the frozen default-enabled `tocCountWords`
/// path (`BookChapterList.kt:236-260`). Remove only the first matched text,
/// including its prefix, without trimming; volume tags bypass decomposition.
String sourceTocTag(String updateTime, {required bool isVolume}) {
  if (isVolume) return updateTime;
  final token = _tocWordCountToken.firstMatch(updateTime)?.group(0);
  return token == null ? updateTime : updateTime.replaceFirst(token, '');
}

/// `HtmlFormatter.wrapHtmlRegex`: the tag family that stands for a paragraph
/// break in the frozen formatter.
final RegExp _wrapHtmlRegex = RegExp(
  r'</?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>',
);

/// `HtmlFormatter.otherHtmlRegex`, the tag pass of `format`'s default call.
final RegExp _otherHtmlRegex = RegExp(r'</?[a-zA-Z]+(?=[ >])[^<>]*>');

/// `HtmlFormatter.notImgHtmlRegex`: the same pass with `img` kept, which is what
/// `formatKeepImg` hands to `format`.
final RegExp _keepImgHtmlRegex = RegExp(r'</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>');

/// Frozen `HtmlFormatter.formatText(html, otherHtmlRegex, paragraphIndent)`:
/// the entity folding, the paragraph-break tag family, comments, the tag pass
/// [otherHtmlRegex] picks, then the paragraph indentation
/// (`HtmlFormatter.kt:39-51`). [paragraphIndent] is the two full-width spaces
/// of `format` or the empty string of `formatIntro`.
String _formatHtml(
  String value,
  RegExp otherHtmlRegex,
  String paragraphIndent,
) => value
    // Frozen `normalizeEscapedLineBreaks` runs before every formatter pass,
    // in this order: `\\r\\n`, `\\n`, `\\r` (`HtmlFormatter.kt:24-29,41`).
    .replaceAll(r'\r\n', '\n')
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\r', '\n')
    .replaceAll(RegExp(r'(&nbsp;)+'), ' ')
    .replaceAll(RegExp(r'(&ensp;|&emsp;)'), ' ')
    .replaceAll(RegExp('(&thinsp;|&zwnj;|&zwj;|\u2009|\u200C|\u200D)'), '')
    .replaceAll(_wrapHtmlRegex, '\n')
    .replaceAll(RegExp(r'<!--[^>]*-->'), '')
    .replaceAll(otherHtmlRegex, '')
    // Java's default \\s is ASCII, unlike Dart's ECMAScript whitespace class.
    .replaceAll(
      RegExp(r'[ \t\n\x0b\f\r]*\n+[ \t\n\x0b\f\r]*'),
      '\n$paragraphIndent',
    )
    .replaceAll(RegExp(r'^[\n \t\x0b\f\r]+'), paragraphIndent)
    .replaceAll(RegExp(r'[\n \t\x0b\f\r]+$'), '');

/// Frozen `HtmlFormatter.formatIntro` used for search and book-information
/// intros (`BookList.kt:260`, `BookInfo.kt:123`): the house tag pass with the
/// empty paragraph indent. The empty indent is also what trims the resulting
/// ASCII paragraph-edge whitespace (`HtmlFormatter.kt:48-50`).
String formatSourceIntro(String value) =>
    _formatHtml(value, _otherHtmlRegex, '');

/// The frozen content stage's own HTML pass, `BookContent.kt:178`:
///
/// ```kotlin
/// content = HtmlFormatter.formatKeepImg(content, rUrl)
/// ```
///
/// A source whose `ruleContent.content` ends in `@html` hands this stage HTML
/// by design — the field is jsoup's `Elements.outerHtml()`, so the tags are the
/// data. The frozen reader turns that HTML into text before any reader sees it,
/// and this is that turn: `formatKeepImg` is `format` with the `img`-keeping
/// tag pass, so the tag family that carries a paragraph break (`div`, `p`, `br`,
/// `hr`, `h\d`, `article`, `dd`, `dl`) becomes a newline, every other tag
/// becomes nothing, an HTML comment is dropped, `&nbsp;`/`&ensp;`/`&emsp;` fold
/// to one space and `&thinsp;`/`&zwnj;`/`&zwj;` (and their literal forms) are
/// removed, then every paragraph is indented — the frozen expression chain, in
/// the frozen order (`tool/html_content_oracle/` executes it as it stands).
///
/// Two divergences are deliberate, and both are recorded rather than hidden:
///
/// - the frozen `formatKeepImg` also rewrites a kept `<img>` element's `src` to
///   an absolute address through `NetworkUtils.getAbsoluteURL(rUrl, …)`. This
///   product reads the element out of the text ([extractChapterImages]) and
///   resolves its address against the chapter's own URL at fetch time, so the
///   markup keeps the source's own text here. `#67` owns the reader's images.
/// - the frozen unescapes entities *after* this pass, and only when a `&`
///   survives it (`BookContent.kt:179-181`), while this product's rule read has
///   already unescaped once (`HtmlRuleBatch.documentText`). The entity branches
///   therefore fire for a rule value that still carries the entity text — a
///   value a `@js:` segment produced — and a page that wrote its tags escaped
///   (`&lt;p&gt;`) keeps them on the frozen side where this pass strips them.
String formatChapterContent(String value) =>
    _formatHtml(value, _keepImgHtmlRegex, '　　');

/// The frozen content stage's whole per-page pass (`BookContent.kt:177-181`):
/// the value `AnalyzeRule.getString(contentRule.content, unescape = false)`
/// produced goes through `HtmlFormatter.formatKeepImg`, and the formatted text
/// then through `StringEscapeUtils.unescapeHtml4` when it still carries `&`.
///
/// [formatChapterContent] is the formatter half alone, the unit the
/// `tool/html_content_oracle/` fixtures compare against `golden.formatted`; this
/// composes it with the frozen's one post-formatter unescape so an escaped-tag
/// page (`&lt;p&gt;`) keeps its tags and a `&nbsp;` run is folded, not resolved,
/// before the fold.
String formatContentPage(String value) {
  final formatted = formatChapterContent(value);
  return formatted.contains('&') ? unescapeHtml4(formatted) : formatted;
}

/// Formats a source word-count value using Legado's `StringUtils.wordCountFormat`.
///
/// Numeric values up to 10,000 are suffixed with `字`; larger positive values
/// are rendered in ten-thousands with at most one decimal and `万字`. Other
/// strings pass through unchanged, while zero and negative numeric values are
/// empty.
String formatSourceWordCount(String value) {
  final numeric = RegExp(r'^-?[0-9]+$').hasMatch(value);
  if (!numeric) return value;
  final count = int.parse(value);
  if (count < -2147483648 || count > 2147483647) {
    throw const FormatException('wordCount 超出冻结 Int 范围');
  }
  if (count <= 0) return '';
  if (count <= 10000) return '$count字';
  // Frozen Kotlin multiplies by 1.0f before dividing as Double. DecimalFormat
  // rounds ties to even; at one decimal, exact binary ties are .25 and .75.
  var units = Float32List.fromList([count.toDouble()]).single / 10000;
  final quarters = units * 4;
  if (quarters == quarters.roundToDouble() && quarters.toInt().isOdd) {
    final lower = (units * 10).floor();
    units = (lower.isEven ? lower : lower + 1) / 10;
  }
  final tenThousands = units
      .toStringAsFixed(1)
      .replaceFirst(RegExp(r'\.0$'), '');
  return '$tenThousands万字';
}

/// The frozen `Book.imageStyle` values (`Book.kt:386-389`), resolved from a
/// source's content rule.
enum SourceImageStyle {
  /// `DEFAULT` (also every value the frozen does not know): the image's own
  /// size, centred.
  natural,

  /// `FULL`: the full width of the reading column.
  full,

  /// `TEXT`: inline in the text, one character cell.
  text,

  /// `SINGLE`: one image per screen.
  single,
}

/// The image style a source declares, from its `ruleContent.imageStyle`.
///
/// The frozen `ReadBook.upWebBook` (`ReadBook.kt:163-177`) reads the field off
/// the content rule when the book carries no style of its own and compares it
/// case-insensitively against `Book.imgStyleFull`/`TEXT`/`SINGLE`; a blank or
/// unknown value is the `DEFAULT` behavior the layouts give their `else`
/// branch.
SourceImageStyle sourceImageStyle(Map<String, dynamic> source) {
  final content = source['ruleContent'];
  final value = content is Map ? content['imageStyle'] : null;
  switch ('$value'.toUpperCase()) {
    case 'FULL':
      return SourceImageStyle.full;
    case 'TEXT':
      return SourceImageStyle.text;
    case 'SINGLE':
      return SourceImageStyle.single;
    default:
      return SourceImageStyle.natural;
  }
}

/// The book-information stage's own result: the book `ruleBookInfo` produced,
/// the TOC address its page declared, and the request context the TOC stage
/// continues from.
///
/// The two frozen stages are separate calls — `WebBook.getBookInfoAwait` then
/// `WebBook.getChapterListAwait` (`WebBook.kt:152-198,224-270`) — so a caller
/// that must observe the information stage on its own (the AUTH runner's
/// details-only step, a page that shows the information before its chapter
/// list) runs [BookSourcePipeline.bookInfo] and stops. The frozen
/// `Book.tocUrl` is the declared address with the `BookInfo.kt:150-152`
/// fallback, which [tocUrl] answers.
class SourceBookInfo {
  const SourceBookInfo({
    required this.book,
    required this.tocAddress,
    required this.tocBase,
    required this.bookUrl,
    required this.bookOptions,
    required this.bookAddress,
    required this.keyword,
    required this.page,
    this.tocHtml,
  });

  /// The book the information stage produced, with the variable text its
  /// carrier was handed.
  final HtmlBook book;

  /// The address text `ruleBookInfo.tocUrl` produced, empty when the page
  /// declared none.
  final String tocAddress;

  /// The base [tocAddress] resolves against: the native logical book/TOC text
  /// for a retained information body, or the actual fetched response URL for a
  /// fetched information response. The historical-relative legacy branch keeps
  /// its original missing-base behavior.
  final Uri tocBase;

  /// The book request's own target, options and address text. The frozen TOC
  /// falls back to the book's own address when the information page declares
  /// none (`BookInfo.kt:150-152`), and that fallback reuses this request.
  final Uri bookUrl;
  final SourceUrlOptions bookOptions;
  final String bookAddress;

  /// The `key`/`page` bindings the information stage ran with. A rule field of
  /// the TOC stage sees this context, never a later search on the same
  /// pipeline: the frozen `AnalyzeUrl` a details stage builds carries the
  /// search's key and no page, and the TOC stage it starts keeps them.
  final String keyword;
  final int? page;

  /// The nonempty information response retained for a same-page TOC handoff.
  /// It is ephemeral result state, not persisted or shared by URL.
  final String? tocHtml;

  /// The frozen `Book.tocUrl` value: the declared address, or the book's own
  /// address text when the page declared none (`BookInfo.kt:150-152`), resolved
  /// against the actual information base and retaining the option tail. A
  /// retained information response contributes its own raw book text as that
  /// base; a fetched one contributes [tocBase] and never old text.
  String get tocUrl => resolveSourceTocUrl(
    address: tocAddress,
    base: tocBase,
    fallbackAddress: bookAddress,
    rawBase: _retainedRawBase,
  );

  /// The raw logical book text, when this information stage read a retained
  /// response instead of fetching one.
  ///
  /// The frozen retained branch hands `book.bookUrl` to `BookInfo` as both the
  /// analyser's base URL and its redirect URL (`WebBook.kt:157-165`), so the
  /// declared address resolves against that raw text. A fetched response owns
  /// its own URL ([tocBase]) and never inherits old book text, which is why this
  /// is the retained response fact rather than a comparison of resolved
  /// components. [HtmlBook.infoHtml] is that retained response and is never
  /// serialized, so the fact cannot outlive the handoff. The text is taken as it
  /// stands and its option boundary is not parsed here.
  String? get _retainedRawBase {
    final retained = book.infoHtml;
    if (retained == null || retained.isEmpty) return null;
    if (sourceKotlinIsBlank(bookAddress)) return null;
    // The base text is kept as the book carried it: the URL constructor's own
    // edge trim stops at U+0020, so a Unicode space is part of the base.
    return bookAddress;
  }
}

/// The full resolved TOC identity, including its requested raw query and its
/// untouched request-option tail. The option text is delimited textually; it is
/// not parsed or validated during information publication.
String resolveSourceTocUrl({
  required String address,
  required Uri base,
  required String fallbackAddress,
  String? rawBase,
}) {
  final value = address.isEmpty ? fallbackAddress : address;
  final boundary = sourceUrlOptionBoundaryOf(value);
  final path = boundary == null ? value : value.substring(0, boundary);
  final tail = boundary == null ? '' : value.substring(boundary);
  // The Kotlin trim belongs to the frozen absolute shortcut only; the relative
  // branch keeps the address text as the rule wrote it, so a Unicode space at
  // either edge is not discarded before the URL constructor sees it.
  final trimmed = sourceKotlinTrim(path);
  final parsed = Uri.tryParse(trimmed);
  final text = parsed != null && parsed.hasScheme
      ? trimmed
      : sourceUrlTextResolved(base, path, rawBase: rawBase);
  return '$text$tail';
}

/// One analysis of one Book Source, as the pages that run a source hold it.
///
/// A source's rules decide which adapter actually runs: [HtmlSourcePipeline]
/// over the Rust rule adapter, or [JsonSourcePipeline] over the bounded
/// JSONPath subset. The shelf, the browser and the reader hold this shape and
/// not a concrete adapter, so a JSON source reaches the shelf and the reader
/// exactly like an HTML one (ticket #29; ADR 0012 unifies the two pipelines
/// here and nowhere else — there is no stage abstraction above them, and no
/// per-source capability record).
///
/// One instance models one analysis, because the frozen `AnalyzeUrl` state —
/// the page, the per-book URL options, the cancellation token — lives on it
/// rather than in method arguments. A page that runs a second analysis opens a
/// second pipeline, and the reader cancels the one it takes over (ticket #26).
///
/// [openBookSourcePipeline] builds the adapter a source's rules need.
abstract interface class BookSourcePipeline {
  /// The imported source object the analysis runs.
  Map<String, dynamic> get source;

  /// The transport the requests go through. A page hands it to the next
  /// pipeline when it hands one over, so one source keeps one transport.
  BookSourceTransport get transport;

  /// Every request the stages have made, in order.
  List<BookSourceTraceEntry> get trace;

  /// Where a source's rate-limited `toast`/`longToast` notices go. Mutable,
  /// because the page that owns the analysis owns its notices.
  void Function(SourceHostMessage message)? get onHostMessage;
  set onHostMessage(void Function(SourceHostMessage message)? value);

  /// `ruleSearch`: the books one keyword search returns.
  Future<List<HtmlBook>> search(String keyword, {int page = 1});

  /// `ruleBookInfo` alone: the book's own page and the TOC address it declares.
  ///
  /// This is the frozen `WebBook.getBookInfoAwait` stage on its own. It fetches
  /// and runs the source's `loginCheckJs` when the hit has no retained
  /// information response; a retained response is consumed without another
  /// request or check. It parses the information rules and makes no TOC
  /// request. [tableOfContents] continues from its result. The hit's variable
  /// text is the candidate a deferred analysis reads and writes; nothing is
  /// stored by this stage.
  Future<SourceBookInfo> bookInfo(HtmlBook hit);

  /// `ruleToc` alone: the chapter list, continued from [info].
  ///
  /// This is the frozen `WebBook.getChapterListAwait` stage: it fetches the
  /// declared TOC address (or the book's own address when the page declared
  /// none), runs the `loginCheckJs` on its first page and walks the declared
  /// pages. A retained first-page body is consumed without another request or
  /// check, and the stage never repeats the information request, its check or
  /// its URL-option evaluation.
  Future<(HtmlBook, List<SourceChapter>)> tableOfContents(SourceBookInfo info);

  /// `ruleBookInfo` plus `ruleToc`: the book's own page and its chapter list.
  ///
  /// The composition of [bookInfo] and [tableOfContents], which is what the
  /// shelf, the browser and the reader run: one call, the information stage then
  /// the TOC stage, consuming retained bodies where the carrier has them and
  /// making the corresponding requests otherwise.
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit);

  /// `ruleContent`: one chapter's text. A reader supplies its selected [book]
  /// when its fresh analysis has not run the details stage.
  ///
  /// [nextChapterUrl] is the next chapter's URL, which the content stage's
  /// `nextContentUrl` walk stops before fetching (`BookContent.kt:85-88`). A
  /// caller that has the chapter list passes it; a caller that does not leaves
  /// it null, and the walk then has no next chapter to stop at — the frozen's
  /// own fallback is the store's chapter at `index + 1`, falling back to the
  /// chapter at index 0, which a pipeline holding no store cannot read.
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  });

  /// One content image's bytes, through this source's own session.
  ///
  /// The frozen reader loads a content image the way it loads any other source
  /// address (`ImageProvider.getImageSize` → `BookHelp.saveImage` →
  /// `AnalyzeUrl(src, source = bookSource).getByteArrayAwait()`): the source's
  /// `header` rule, its login header, its cookie jar, its `concurrentRate` and
  /// its per-source TLS exception. [src] is one image's own address text, as
  /// [HtmlChapterBody.images] carries it; [base] resolves a relative one, and
  /// the chapter's own URL is what the frozen download path resolves against.
  Future<Uint8List> chapterImage(String src, {Uri? base});

  /// Ends this analysis: a stage in flight stops at its next check, and every
  /// stage after it refuses to start.
  void cancel();
}

/// Whether a source's rules are the JSON adapter's.
///
/// The frozen `AnalyzeUrl` picks its mode per rule, and this product has two
/// adapters, so one place decides which pipeline a source gets — the search
/// list rule's own shape. `@Json:`-prefixed rules are classified JSON,
/// case-insensitively, as in the frozen `SourceRule` mode selection.
bool isJsonRuleSource(Map<String, dynamic> source) {
  final search = source['ruleSearch'];
  final listRule = search is Map ? '${search['bookList'] ?? ''}' : '';
  return listRule.toLowerCase().startsWith('@json:') ||
      listRule.startsWith(r'$.') ||
      listRule.startsWith(r'$[');
}

/// The pipeline a source's rules need, over [transport].
///
/// Every page that runs a source builds it through here, so the shelf, the
/// browser, the reader and the trial page cannot disagree about which adapter
/// a source gets.
BookSourcePipeline openBookSourcePipeline(
  Map<String, dynamic> source,
  BookSourceTransport transport, {
  SourceHostState? hostState,
  String androidId = '',
  bool deferEntityVariables = false,
  void Function(SourceHostMessage message)? onHostMessage,
}) => isJsonRuleSource(source)
    ? JsonSourcePipeline(
        source,
        transport,
        hostState: hostState,
        androidId: androidId,
        deferEntityVariables: deferEntityVariables,
        onHostMessage: onHostMessage,
      )
    : HtmlSourcePipeline(
        source,
        transport,
        hostState: hostState,
        androidId: androidId,
        deferEntityVariables: deferEntityVariables,
        onHostMessage: onHostMessage,
      );
