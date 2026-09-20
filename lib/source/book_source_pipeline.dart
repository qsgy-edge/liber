import 'dart:typed_data';

import 'book_source_service.dart';
import 'html_source_pipeline.dart';
import 'json_source_pipeline.dart';
import 'js_source_runtime.dart' show SourceHostMessage;
import 'source_host_state.dart';

/// The shapes the pages hold come with the interface, so a caller that runs a
/// source needs one import for them: [HtmlBook] and [HtmlChapterBody] from the
/// HTML adapter's file, [SourceChapter] from the JSON adapter's.
export 'html_source_pipeline.dart' show HtmlBook, HtmlChapterBody;
export 'json_source_pipeline.dart' show SourceChapter;

/// The frozen source's default search keyword (`BookSource.getCheckKeyword`).
///
/// See `BookSource.kt:208-215` in Legado baseline `14dd24945`: a nonblank
/// `ruleSearch.checkKeyWord` wins without trimming the value; otherwise the
/// caller's fallback is used.
String sourceCheckKeyword(Map<String, dynamic> source, String fallback) {
  final search = source['ruleSearch'];
  final value = search is Map ? search['checkKeyWord'] : null;
  if (value == null) return fallback;
  if (value is! String) {
    throw const FormatException('ruleSearch.checkKeyWord 必须是字符串规则');
  }
  return value.trim().isNotEmpty ? value : fallback;
}

/// Frozen HtmlFormatter.format used for search and book-information intros.
String formatSourceIntro(String value) => value
    .replaceAll(RegExp(r'(&nbsp;)+'), ' ')
    .replaceAll(RegExp(r'(&ensp;|&emsp;)'), ' ')
    .replaceAll(RegExp('(&thinsp;|&zwnj;|&zwj;|\u2009|\u200C|\u200D)'), '')
    .replaceAll(RegExp(r'</?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>'), '\n')
    .replaceAll(RegExp(r'<!--[^>]*-->'), '')
    .replaceAll(RegExp(r'</?[a-zA-Z]+(?=[ >])[^<>]*>'), '')
    // Java's default \\s is ASCII, unlike Dart's ECMAScript whitespace class.
    .replaceAll(RegExp(r'[ \t\n\x0b\f\r]*\n+[ \t\n\x0b\f\r]*'), '\n　　')
    .replaceAll(RegExp(r'^[\n \t\x0b\f\r]+'), '　　')
    .replaceAll(RegExp(r'[\n \t\x0b\f\r]+$'), '');

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

  /// `ruleBookInfo` plus `ruleToc`: the book's own page and its chapter list.
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit);

  /// `ruleContent`: one chapter's text. A reader supplies its selected [book]
  /// when its fresh analysis has not run the details stage.
  Future<HtmlChapterBody> chapter(SourceChapter chapter, {HtmlBook? book});

  /// Ends this analysis: a stage in flight stops at its next check, and every
  /// stage after it refuses to start.
  void cancel();
}

/// Whether a source's rules are the JSON adapter's.
///
/// The frozen `AnalyzeUrl` picks its mode per rule, and this product has two
/// adapters, so one place decides which pipeline a source gets — the search
/// list rule's own shape. `@Json:`-prefixed rules are classified JSON, as they
/// already were in the trial page, even though the JSON rule reader does not
/// accept the prefix yet: the error it raises then names the rule that has to
/// change instead of blaming the HTML adapter.
bool isJsonRuleSource(Map<String, dynamic> source) {
  final search = source['ruleSearch'];
  final listRule = search is Map ? '${search['bookList'] ?? ''}' : '';
  return listRule.startsWith('@Json:') ||
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
  void Function(SourceHostMessage message)? onHostMessage,
}) => isJsonRuleSource(source)
    ? JsonSourcePipeline(
        source,
        transport,
        hostState: hostState,
        androidId: androidId,
        onHostMessage: onHostMessage,
      )
    : HtmlSourcePipeline(
        source,
        transport,
        hostState: hostState,
        androidId: androidId,
        onHostMessage: onHostMessage,
      );
