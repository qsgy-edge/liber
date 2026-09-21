/// The user's replace rules, applied to the reading paths the way the frozen
/// reader applies them.
///
/// The frozen reader replaces text before it reaches the screen: for a text book
/// the rules are on by default (`Book.getUseReplaceRule()` falls back to
/// `AppConfig.replaceEnableDefault`, which is `true`; image and epub books
/// default off), and they run on **both** the table-of-contents titles
/// (`BookChapter.getDisplayTitle`, `BookChapter.kt:100-139`, and its call sites
/// `ReadBook.kt:694/767`, `BookChapterList.kt:152-163`) and the chapter content
/// (`ContentProcessor.getContent`, `ContentProcessor.kt:93-198`).
///
/// One instance is one analysis of one book: [ReplaceRuleSet.forBook] selects the
/// rules the frozen `ReplaceRuleDao` would return for this book
/// (`ReplaceRuleDao.kt:59-72`), and the two public entry points are the two the
/// frozen reader has — [displayTitle] and [content]:
///
/// - the reader's chapter title (`ReadBook.kt:694`) is [displayTitle];
/// - the reader's page body (`ReadBook.kt:699/772`, called with
///   `includeTitle = false`) is [content].
///
/// The table-of-contents **list** is deliberately not [displayTitle]'d here: the
/// frozen list applies it only when `AppConfig.tocUiUseReplace` is on
/// (`ChapterListAdapter.kt:78`), which defaults to false and is false in the
/// operator's own configuration, so the frozen default is a list of raw titles.
///
/// The frozen `getContent` ends by reshaping the text, and that shaping is the
/// boundary #17 pins: split on `\n`, trim every paragraph from both ends of the
/// cutset `code <= 0x20 || it == '　'`, drop empty paragraphs, and prefix each
/// remaining one with `ReadBookConfig.paragraphIndent`
/// (`ContentProcessor.kt:185-201`). The frozen default of that setting is two
/// ideographic spaces (`ReadBookConfig.kt:532`); [content] uses that constant
/// until a settings ticket owns the reader's indent. The frozen
/// `if (contents.isEmpty() && includeTitle)` condition leaves the first
/// paragraph unindented when `includeTitle` is true. The frozen `isAndroid8`
/// branch rewriting `\u00A0` to a space (`ContentProcessor.kt:182-184`) is not
/// reproduced: the pinned capture device runs Android 17, where `isAndroid8` is
/// false, so that rewrite is not this release's observed behavior.
///
/// The `ContentHelp.reSegment` stage (`ContentProcessor.kt:131-133`, the
/// per-book `Book.getReSegment()` switch) is ported in `content_re_segment.dart`
/// and runs in the frozen position — after the duplicated-title removal, before
/// the conversion — when [ContentProcessing.useReSegment] is set. The product has
/// no per-book reading-flag storage yet, so the reader passes the frozen default
/// (off, 21 of the operator's 1419 books carry it on); the flag is the caller's,
/// the way [ContentProcessing.useReplaceRule] is. The transform is deterministic
/// except for `forceSplit`'s `Math.random()` branch (`ContentHelp.kt:160`), which
/// cannot be compared byte for byte against an unseeded frozen run.
///
/// What this module does **not** do, and why — these are recorded on #17:
///
/// - an `@js:` replacement (`RegexExtensions.kt:23-64`) evaluates JavaScript
///   once per regex match through the approved source runtime boundary; the
///   frozen runtime exposes the complete match as `result`, and the returned
///   value is inserted literally.
/// - the frozen `removeSameTitleCache` guard (`ContentProcessor.kt:126-128`)
///   depends on the retired on-disk chapter files, which this product has none
///   of, so the duplicated-title removal always runs.
/// - SQLite's `LIKE` would read a `%` or `_` **inside a book's name or origin**
///   as a wildcard; this selection compares them literally.
/// - a Java pattern the Dart engine cannot express (atomic groups, possessive
///   quantifiers, character-class intersection, `\Q...\E`, `\Z`, `\G`, `\cX`,
///   the `d`/`u`/`U`/`x` flags) is refused by name instead of mis-applied; see
///   `java_regex.dart` for what is translated.
///
/// A **regex** rule runs in its own isolate, so only a plain (non-widget) test can
/// exercise it: a widget test's binding does not deliver another isolate's
/// messages, the way it cannot settle `flutter_rust_bridge`'s pending work. A
/// widget test that drives a reader must use literal rules (or a fake processor),
/// and `content_processing_test.dart` carries the regex and deadline cases.
library;

import 'dart:isolate';

import '../domain/contracts.dart'
    show SourceCancellation, SourceRequestCancelled;
import '../local/reader_engine.dart' show ReaderScript;
import '../local/text_engine.dart' show TextEngine;
import '../store/database.dart' show ReplaceRule;
import 'content_re_segment.dart';
import 'java_regex.dart';
import 'js_source_runtime.dart'
    show InProcessSourceScriptRuntime, SourceScriptError, SourceScriptRuntime;

/// The rules the frozen `ReplaceRuleDao` returns for one book, in the frozen
/// order.
///
/// The two frozen queries are the same statement twice, once per scope column
/// (`ReplaceRuleDao.kt:59-72`):
///
/// ```sql
/// WHERE isEnabled = 1 AND scopeContent = 1
///   AND (scope LIKE '%' || :name || '%' OR scope LIKE '%' || :origin || '%'
///        OR scope IS NULL OR scope = '')
///   AND (excludeScope IS NULL
///        OR (excludeScope NOT LIKE '%' || :name || '%'
///            AND excludeScope NOT LIKE '%' || :origin || '%'))
/// ORDER BY sortOrder
/// ```
///
/// `scope` is a *substring* match against the book's name or its origin (a
/// source's URL; a local book's origin is the frozen `loc_book`, `BookType.kt:66`)
/// and SQLite's `LIKE` folds ASCII case, so this does too.
class ReplaceRuleSet {
  const ReplaceRuleSet({required this.titleRules, required this.contentRules});

  /// Enabled title-scope rules that reach this book, in the frozen order.
  final List<ReplaceRule> titleRules;

  /// Enabled content-scope rules that reach this book, in the frozen order.
  final List<ReplaceRule> contentRules;

  factory ReplaceRuleSet.forBook(
    Iterable<ReplaceRule> rules, {
    required String bookName,
    required String bookOrigin,
  }) {
    final title = <ReplaceRule>[];
    final content = <ReplaceRule>[];
    for (final rule in rules) {
      if (_selects(
        rule,
        name: bookName,
        origin: bookOrigin,
        scopeTitle: true,
      )) {
        title.add(rule);
      }
      if (_selects(
        rule,
        name: bookName,
        origin: bookOrigin,
        scopeTitle: false,
      )) {
        content.add(rule);
      }
    }
    // `ORDER BY sortOrder`: the order field, ties keeping the order the store
    // returned them in (`replaceRules()` orders by (ruleOrder, id)).
    return ReplaceRuleSet(
      titleRules: _sorted(title),
      contentRules: _sorted(content),
    );
  }
}

/// A stable sort by [ReplaceRule.ruleOrder]; `List.sort` is not stable, so the
/// incoming index is the tiebreak and two rules sharing one order both stay.
List<ReplaceRule> _sorted(List<ReplaceRule> rules) {
  final order = List.generate(rules.length, (index) => index);
  order.sort((a, b) {
    final byOrder = rules[a].ruleOrder.compareTo(rules[b].ruleOrder);
    return byOrder != 0 ? byOrder : a.compareTo(b);
  });
  return [for (final index in order) rules[index]];
}

bool _selects(
  ReplaceRule rule, {
  required String name,
  required String origin,
  required bool scopeTitle,
}) {
  if (!rule.isEnabled) return false;
  if (scopeTitle ? !rule.scopeTitle : !rule.scopeContent) return false;
  final scope = rule.scope;
  if (scope != null && scope.isNotEmpty) {
    if (!_like(scope, name) && !_like(scope, origin)) return false;
  }
  final exclude = rule.excludeScope;
  if (exclude != null && (_like(exclude, name) || _like(exclude, origin))) {
    return false;
  }
  return true;
}

/// SQLite's `haystack LIKE '%needle%'`: a substring test that folds ASCII case.
bool _like(String haystack, String needle) =>
    _asciiLower(haystack).contains(_asciiLower(needle));

String _asciiLower(String text) {
  final out = StringBuffer();
  for (final unit in text.codeUnits) {
    out.writeCharCode(unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit);
  }
  return out.toString();
}

/// Applies a [ReplaceRuleSet] to one book's titles and content.
///
/// The rules run in the frozen order. A pattern the engine cannot express or
/// an ordinary replacement error is reported and left out; a timed-out rule is
/// reported, disabled through [onRuleDisabled], and left out. JavaScript
/// replacement calls use the same per-rule deadline and cancellation signal as
/// the approved source runtime.
class ContentProcessing {
  ContentProcessing({
    required this.rules,
    required this.bookName,
    this.script,
    this.scriptRuntime,
    this.cancellation,
    this.useReplaceRule = true,
    this.useReSegment = false,
    this.timeoutFallback = const Duration(milliseconds: 3000),
    this.onNotice,
    this.onRuleDisabled,
  });

  /// The rules that reach this book.
  final ReplaceRuleSet rules;

  /// The book's name, which the duplicated-title removal needs: the frozen
  /// reader allows the book's own name as leading noise before the title
  /// (`Pattern.quote(book.name)`).
  final String bookName;

  /// The script the page was asked to render, or null for the text as it is.
  /// Which one a reader wants is #27's choice; the conversion itself is ADR
  /// 0010's, and the frozen engine converts inside this same stage.
  final ReaderScript? script;

  /// The approved JavaScript boundary used for `@js:` replacements. Tests may
  /// inject a boundary double; the product uses the in-process source runtime.
  final SourceScriptRuntime? scriptRuntime;

  /// Cancels an in-flight JavaScript replacement when the reader's operation
  /// is abandoned.
  final SourceCancellation? cancellation;

  /// The frozen `Book.getUseReplaceRule()`: the per-book switch falling back to
  /// the reader-wide default. This product has no settings surface yet, so the
  /// callers pass the frozen text-book default (on).
  final bool useReplaceRule;

  /// The frozen `Book.getReSegment()`: the per-book switch that turns the
  /// `ContentHelp.reSegment` stage on. It is a *separate* switch from
  /// [useReplaceRule] and defaults off in the frozen reader (21 of the
  /// operator's 1419 books have it on). The product has no per-book
  /// reading-flag storage yet (the map's settings fog, P6), so the reader passes
  /// the frozen default (off); the caller owns the value.
  final bool useReSegment;

  /// The frozen `ReplaceRule.getValidTimeoutMillisecond()`: a rule's own value,
  /// or 3000 ms when it is non-positive.
  final Duration timeoutFallback;

  /// Where a skipped rule is reported. Each rule is reported at most once per
  /// instance, so a chapter-by-chapter report cannot flood the reader.
  final void Function(String message)? onNotice;

  /// Called when a rule exceeded its deadline. The frozen reader disables such a
  /// rule in the database (`ContentProcessor.kt:169-171`), which is why the
  /// caller can persist that here.
  final Future<void> Function(ReplaceRule rule)? onRuleDisabled;

  final Set<String> _reported = {};

  /// The chapter title as the frozen reader shows it
  /// (`BookChapter.getDisplayTitle`): line breaks stripped, converted when a
  /// script was asked for, then the title rules applied — a rule's result is
  /// adopted only when it is not blank.
  Future<String> displayTitle(String title) =>
      _titleWithRules(title, rules.titleRules, convert: true);

  /// The chapter body as the frozen reader reads it
  /// (`ContentProcessor.getContent(..., includeTitle = false)`), in the frozen
  /// order: the duplicate leading title, the optional re-segmentation, the
  /// conversion, the per-line trim the replace stage does, the content rules,
  /// and finally the frozen paragraph shaping whose joined result is the frozen
  /// `BookContent.toString()` the #17 boundary pins.
  ///
  /// [includeTitle] is the frozen `includeTitle` argument: when true, the display
  /// title is prepended as its own line, which is where the frozen content stage
  /// puts it before the reader splits the body into paragraphs, and the shaping
  /// then leaves that first paragraph unindented.
  Future<String> content(
    String raw, {
    required String chapterTitle,
    bool includeTitle = false,
  }) async {
    // The frozen guard: a source stage that produced nothing hands over the
    // literal text "null", which is not content and is not processed.
    if (raw == 'null') return raw;
    var text = await _removeDuplicatedTitle(raw, chapterTitle);
    // The frozen `if (reSegment && book.getReSegment())`
    // (`ContentProcessor.kt:131-133`): after the duplicate-title removal, before
    // the conversion and the replace rules. It re-segments on the *raw* chapter
    // title, the one the title pattern above also used. Because it changes the
    // body before the reader computes its line offsets, enabling it for a book
    // moves that book's stored positions, exactly as the frozen reader's do
    // (see #47 for the local reader's offset model).
    if (useReSegment) text = reSegment(text, chapterTitle);
    if (script != null) text = _convert(text);
    if (useReplaceRule) {
      // The replace stage trims every line before the rules see it.
      text = text.split('\n').map((line) => line.trim()).join('\n');
      for (final rule in rules.contentRules) {
        if (rule.pattern.isEmpty) continue;
        text = await _apply(text, rule) ?? text;
      }
    }
    if (includeTitle) {
      text = '${await displayTitle(chapterTitle)}\n$text';
    }
    return _shapeParagraphs(text, includeTitle: includeTitle);
  }

  Future<String> _titleWithRules(
    String title,
    List<ReplaceRule> source, {
    required bool convert,
  }) async {
    var text = title.replaceAll(RegExp(r'[\r\n]'), '');
    if (convert && script != null) text = _convert(text);
    if (!useReplaceRule) return text;
    for (final rule in source) {
      if (rule.pattern.isEmpty) continue;
      final candidate = await _apply(text, rule);
      if (candidate != null && candidate.trim().isNotEmpty) text = candidate;
    }
    return text;
  }

  /// The frozen duplicated-leading-title removal (`ContentProcessor.kt:120-135`).
  ///
  /// The first pattern is the raw chapter title with every whitespace run as
  /// `\s*` and the book's own name allowed as leading punctuation noise; when it
  /// does not match, the frozen reader retries with the title the **content**
  /// rules produce — a quirk: the content rules, and without conversion.
  Future<String> _removeDuplicatedTitle(
    String content,
    String chapterTitle,
  ) async {
    final rawTitle = RegExp(
      '$_leading${_javaTitlePattern(chapterTitle)}$_javaSpaceStar',
      unicode: true,
    ).firstMatch(content);
    if (rawTitle != null) return content.substring(rawTitle.end);
    if (!useReplaceRule) return content;
    final processed = await _titleWithRules(
      chapterTitle,
      rules.contentRules,
      convert: false,
    );
    if (processed.isEmpty) return content;
    final retry = RegExp(
      '$_leading${_javaQuoted(processed)}$_javaSpaceStar',
      unicode: true,
    ).firstMatch(content);
    if (retry != null) return content.substring(retry.end);
    return content;
  }

  /// `^(\s|\p{P}|<quoted book name>)*` in the frozen reader's own words: Java's
  /// ASCII `\s` (which includes the space), Unicode punctuation, and the book's
  /// name quoted.
  String get _leading => '^($_javaSpaceClass|\\p{P}|${_javaQuoted(bookName)})*';

  Future<String?> _apply(String text, ReplaceRule rule) async {
    final translated = rule.isRegex ? translateJavaPattern(rule.pattern) : null;
    if (translated != null && !translated.isRunnable) {
      _reportOnce(rule, '替换规则「${rule.name}」不可用：${translated.refusal}');
      return null;
    }
    if (!rule.isRegex) {
      // Kotlin's literal `String.replace`, which is what the frozen content path
      // uses for a non-regex rule — including a replacement that starts with
      // `@js:`, which the literal branch never interprets.
      return text.replaceAll(rule.pattern, rule.replacement);
    }
    if (rule.replacement.startsWith('@js:')) {
      final outcome = await _applyJsUnderDeadline(text, rule, translated!);
      if (outcome.cancelled) return null;
      if (outcome.timedOut) {
        _reportOnce(
          rule,
          '替换规则「${rule.name}」超时（${_deadlineFor(rule).inMilliseconds} 毫秒），已停用',
        );
        await onRuleDisabled?.call(rule);
        return null;
      }
      if (outcome.error != null) {
        _reportOnce(rule, '替换规则「${rule.name}」出错：${outcome.error}');
        return null;
      }
      return outcome.text;
    }
    final outcome = await _applyUnderDeadline(text, rule, translated!);
    if (outcome.timedOut) {
      _reportOnce(
        rule,
        '替换规则「${rule.name}」超时（${_deadlineFor(rule).inMilliseconds} 毫秒），已停用',
      );
      await onRuleDisabled?.call(rule);
      return null;
    }
    if (outcome.error != null) {
      _reportOnce(rule, '替换规则「${rule.name}」出错：${outcome.error}');
      return null;
    }
    return outcome.text;
  }

  void _reportOnce(ReplaceRule rule, String message) {
    if (!_reported.add(rule.id)) return;
    onNotice?.call(message);
  }

  Duration _deadlineFor(ReplaceRule rule) => rule.timeoutMillisecond <= 0
      ? timeoutFallback
      : Duration(milliseconds: rule.timeoutMillisecond);

  String _convert(String text) => switch (script) {
    null => text,
    ReaderScript.simplified => TextEngine.t2s(text),
    ReaderScript.traditional => TextEngine.s2t(text),
  };

  /// Applies the frozen JavaScript replacement once per match. The stopwatch
  /// carries one rule deadline across all matches, matching the frozen worker
  /// that wraps the complete replacement pass in one timeout.
  Future<_Outcome> _applyJsUnderDeadline(
    String text,
    ReplaceRule rule,
    JavaPattern pattern,
  ) async {
    final runtime = scriptRuntime ?? InProcessSourceScriptRuntime();
    final script = rule.replacement.substring(4);
    final deadline = _deadlineFor(rule);
    final stopwatch = Stopwatch()..start();
    final buffer = StringBuffer();
    var cursor = 0;
    try {
      final remaining = deadline - stopwatch.elapsed;
      if (remaining <= Duration.zero) return const _Outcome.timeout();
      final matches = await _collectJsMatches(text, pattern, remaining);
      if (matches.cancelled) return const _Outcome.cancelled();
      if (matches.timedOut) return const _Outcome.timeout();
      if (matches.error != null) return _Outcome.error(matches.error!);
      for (final entry in matches.values!) {
        final start = entry[0] as int;
        final end = entry[1] as int;
        final matchText = entry[2] as String;
        final next = deadline - stopwatch.elapsed;
        if (next <= Duration.zero) return const _Outcome.timeout();
        final value = await runtime.evaluate(
          source: script,
          input: {'sourceKey': '', 'result': matchText},
          timeout: next,
          cancellation: cancellation,
        );
        cancellation?.throwIfCancelled();
        buffer.write(text.substring(cursor, start));
        // Matcher.appendReplacement quotes the script result. Building the
        // output directly has the same effect for '$' and '\\' characters.
        buffer.write('$value');
        cursor = end;
      }
      buffer.write(text.substring(cursor));
      return _Outcome.text(buffer.toString());
    } on SourceScriptError catch (error) {
      if (error.category == 'cancelled') return const _Outcome.cancelled();
      if (error.category == 'timeout') return const _Outcome.timeout();
      return _Outcome.error('$error');
    } on SourceRequestCancelled {
      return const _Outcome.cancelled();
    } catch (error) {
      return _Outcome.error('$error');
    }
  }

  Future<_JsMatches> _collectJsMatches(
    String text,
    JavaPattern pattern,
    Duration timeout,
  ) async {
    if (cancellation?.isCancelled ?? false) return const _JsMatches.cancelled();
    final receive = ReceivePort();
    Isolate? isolate;
    final unlisten = cancellation?.listen(() {
      isolate?.kill(priority: Isolate.immediate);
    });
    try {
      isolate = await Isolate.spawn(_jsMatchEntry, <Object?>[
        receive.sendPort,
        pattern.source,
        text,
        pattern.caseSensitive,
        pattern.multiLine,
        pattern.dotAll,
        pattern.unicode,
      ], onExit: receive.sendPort);
      // Cancellation can arrive while spawn is awaiting the isolate handle.
      if (cancellation?.isCancelled ?? false) {
        return const _JsMatches.cancelled();
      }
      final message = await receive.first.timeout(
        timeout,
        onTimeout: () => const <Object?>['timeout'],
      );
      if (message is List && message.isNotEmpty && message.first == 'timeout') {
        return const _JsMatches.timeout();
      }
      if (message == null) {
        return cancellation?.isCancelled ?? false
            ? const _JsMatches.cancelled()
            : const _JsMatches.error('替换进程意外退出');
      }
      if (message is! List || message.length < 2) {
        return const _JsMatches.error('替换进程返回了意外结果');
      }
      if (message.first == 'error') {
        return _JsMatches.error('${message[1]}');
      }
      if (message.first != 'ok' || message[1] is! List) {
        return const _JsMatches.error('替换进程返回了意外结果');
      }
      final values = <List<Object?>>[];
      for (final value in message[1] as List) {
        if (value is! List ||
            value.length != 3 ||
            value[0] is! int ||
            value[1] is! int ||
            value[2] is! String) {
          return const _JsMatches.error('替换进程返回了意外匹配');
        }
        values.add(value.cast<Object?>());
      }
      return _JsMatches.values(values);
    } finally {
      unlisten?.call();
      isolate?.kill(priority: Isolate.immediate);
      receive.close();
    }
  }

  /// Runs one regex rule in a short-lived isolate under the rule's own deadline.
  ///
  /// The frozen engine runs the replacement on a worker and cancels it when the
  /// timeout elapses (`RegexExtensions.kt:29-63`); Dart's `RegExp` cannot be
  /// interrupted, so the pass runs in an isolate that is killed at the deadline.
  /// The rule that exceeded its own timeout is therefore the rule reported, which
  /// is the frozen attribution.
  Future<_Outcome> _applyUnderDeadline(
    String text,
    ReplaceRule rule,
    JavaPattern pattern,
  ) async {
    final receive = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(_replaceEntry, <Object?>[
        receive.sendPort,
        pattern.source,
        rule.replacement,
        text,
        pattern.caseSensitive,
        pattern.multiLine,
        pattern.dotAll,
        pattern.unicode,
      ], onExit: receive.sendPort);
      final message = await receive.first.timeout(
        _deadlineFor(rule),
        onTimeout: () => const <Object?>['timeout'],
      );
      if (message == null) {
        return const _Outcome.error('替换进程意外退出');
      }
      if (message is! List || message.isEmpty) {
        return const _Outcome.error('替换进程返回了意外结果');
      }
      switch (message.first) {
        case 'ok':
          return _Outcome.text('${message[1]}');
        case 'timeout':
          return const _Outcome.timeout();
        default:
          return _Outcome.error(
            '${message.length > 1 ? message[1] : message.first}',
          );
      }
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      receive.close();
    }
  }
}

/// `ReadBookConfig.paragraphIndent`'s frozen default (`ReadBookConfig.kt:532`).
/// The reader's indent is a reading setting; until a settings ticket owns it,
/// [ContentProcessing.content] uses this constant, the value the pinned oracle
/// captures.
const _paragraphIndent = '　　';

/// The frozen `ContentProcessor.kt:185-201` paragraph shaping, whose result is
/// the frozen `BookContent.toString()`: paragraphs joined by newlines. Each
/// paragraph is trimmed of the frozen cutset `code <= 0x20 || it == '　'` — not
/// Dart's wider `String.trim` — empty paragraphs are dropped, and every
/// remaining paragraph is indented except the first when [includeTitle] makes it
/// the title.
String _shapeParagraphs(String text, {required bool includeTitle}) {
  final paragraphs = <String>[];
  for (final line in text.split('\n')) {
    final paragraph = _trimFrozen(line);
    if (paragraph.isEmpty) continue;
    paragraphs.add(
      paragraphs.isEmpty && includeTitle
          ? paragraph
          : '$_paragraphIndent$paragraph',
    );
  }
  return paragraphs.join('\n');
}

/// The frozen `str.trim { it.code <= 0x20 || it == '　' }`: Java's control/space
/// range plus the ideographic space, both ends.
String _trimFrozen(String text) {
  bool trimmed(int codeUnit) => codeUnit <= 0x20 || codeUnit == 0x3000;
  var start = 0;
  var end = text.length;
  while (start < end && trimmed(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && trimmed(text.codeUnitAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

class _JsMatches {
  const _JsMatches.values(this.values)
    : timedOut = false,
      cancelled = false,
      error = null;
  const _JsMatches.timeout()
    : values = null,
      timedOut = true,
      cancelled = false,
      error = null;
  const _JsMatches.cancelled()
    : values = null,
      timedOut = false,
      cancelled = true,
      error = null;
  const _JsMatches.error(this.error)
    : values = null,
      timedOut = false,
      cancelled = false;

  final List<List<Object?>>? values;
  final bool timedOut;
  final bool cancelled;
  final String? error;
}

class _Outcome {
  const _Outcome.text(this.text)
    : timedOut = false,
      cancelled = false,
      error = null;
  const _Outcome.timeout()
    : text = null,
      timedOut = true,
      cancelled = false,
      error = null;
  const _Outcome.cancelled()
    : text = null,
      timedOut = false,
      cancelled = true,
      error = null;
  const _Outcome.error(this.error)
    : text = null,
      timedOut = false,
      cancelled = false;
  final String? text;
  final bool timedOut;
  final bool cancelled;
  final String? error;
}

/// Collects complete regex matches off the reading isolate. The JavaScript
/// runtime remains the approved boundary in the caller isolate; this worker
/// only makes Dart's regexp work interruptible under the same rule deadline.
void _jsMatchEntry(List<Object?> args) {
  final send = args[0] as SendPort;
  try {
    final regex = RegExp(
      args[1] as String,
      caseSensitive: args[3] as bool,
      multiLine: args[4] as bool,
      dotAll: args[5] as bool,
      unicode: args[6] as bool,
    );
    final text = args[2] as String;
    final matches = <List<Object?>>[];
    for (final match in regex.allMatches(text)) {
      matches.add(<Object?>[match.start, match.end, match.group(0)!]);
    }
    send.send(<Object?>['ok', matches]);
  } catch (error) {
    send.send(<Object?>['error', '$error']);
  }
}

/// The isolate entry point: one Java-compatible replacement, off the reading
/// isolate, with the text it is given as the only thing copied.
void _replaceEntry(List<Object?> args) {
  final send = args[0] as SendPort;
  final source = args[1] as String;
  final replacement = args[2] as String;
  final text = args[3] as String;
  try {
    final regex = RegExp(
      source,
      caseSensitive: args[4] as bool,
      multiLine: args[5] as bool,
      dotAll: args[6] as bool,
      unicode: args[7] as bool,
    );
    final buffer = StringBuffer();
    var cursor = 0;
    for (final match in regex.allMatches(text)) {
      buffer.write(text.substring(cursor, match.start));
      final expanded = expandJavaReplacement(replacement, match);
      if (expanded == null) {
        send.send(const <Object?>['error', '替换里的分组引用不存在']);
        return;
      }
      buffer.write(expanded);
      cursor = match.end;
    }
    buffer.write(text.substring(cursor));
    send.send(<Object?>['ok', buffer.toString()]);
  } catch (error) {
    send.send(<Object?>['error', '$error']);
  }
}

/// Java's `\s` set as a character class: the ASCII whitespace Java uses, and
/// ECMAScript does not (ECMAScript's `\s` also matches `\u00A0` and friends).
const _javaSpaceClass = r'[ \t\n\x0B\f\r]';

const _javaSpaceStar = '$_javaSpaceClass*';

/// The frozen `escapeRegex()`: every regular-expression metacharacter of a title,
/// quoted so it matches itself.
String _javaQuoted(String text) => RegExp.escape(text);

/// The frozen title pattern: the escaped title with every whitespace run
/// replaced by Java's `\s*`, which in ECMAScript is the ASCII set Java uses.
String _javaTitlePattern(String title) => title
    .split(RegExp('$_javaSpaceClass+'))
    .map(_javaQuoted)
    .join(_javaSpaceStar);
