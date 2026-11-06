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
///   once per regex match through the approved source runtime boundary, which
///   exposes the complete match as `result`. A **regex** rule expands the
///   returned text the way the selected reference does — `$0`/`$n`/`${name}`
///   capture references against the original match, with literal backslashes —
///   while a non-regex rule inserts its replacement literally and never
///   interprets the prefix. The text those capture references insert is limited
///   to 8 MiB of UTF-8 bytes per rule execution, cumulatively over its matches;
///   exceeding it is an ordinary rule failure that keeps the rule enabled. That
///   resource policy is this product's, and differs from the selected
///   reference's per-rule timeout and attempted restart.
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
///
/// [ContentProcessing.content] also returns the **edit script** of the run it
/// performed — every range of its input it rewrote, inserted or deleted, with the
/// length it became ([ProcessedContent]). The stage that rewrites the text is the
/// only place that knows this, so a caller that has to translate a position
/// stored in the raw text into the processed text (the local reader's progress
/// record, in `lib/local/reader_offset_map.dart`) reads the script instead of
/// comparing the two texts. A stage whose rewrite is not a range of the input —
/// the re-segmentation switch, which moves characters between paragraphs —
/// reports its whole text as one rewritten range: the script never guesses.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:fjs/fjs.dart' show ConvertTarget;

import '../domain/contracts.dart'
    show SourceCancellation, SourceRequestCancelled;
import '../domain/store_message.dart';
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

/// One range of a text a processing stage rewrote, in that text's own offsets:
/// the code units `[start, end)` became [length] code units of the stage's
/// output. A zero-width range is text the stage inserted; a zero [length] is
/// text it deleted. A range of equal length whose content changed (an in-place
/// rewrite) is not reported: position `i` of the range became position `i` of
/// the result, so nothing about it needs translating.
class ContentEdit {
  const ContentEdit({
    required this.start,
    required this.end,
    required this.length,
  });

  /// The first code unit of the input range.
  final int start;

  /// One past the last code unit of the input range.
  final int end;

  /// How many code units the stage's output has where the range was.
  final int length;

  @override
  String toString() => 'ContentEdit($start..$end -> $length)';
}

/// What one [ContentProcessing.content] call produced: the text, and the edit
/// script that turned the text it was given into it.
///
/// [edits] is ascending and disjoint: outside its ranges the input's own
/// offsets line up exactly, shifted by the lengths the earlier ranges add or
/// remove; a reported range is one whose length changed. That is enough
/// to translate any offset of the input into the output and back
/// (`lib/local/reader_offset_map.dart`): outside a range the translation is
/// exact, and inside one — where the run replaced or removed the text — the
/// offset resolves to the range's own boundary.
class ProcessedContent {
  const ProcessedContent({required this.text, required this.edits});

  /// The processed text, exactly what the frozen pipeline produces.
  final String text;

  /// The ranges of the input the run rewrote, in the input's offsets.
  final List<ContentEdit> edits;
}

/// Applies a [ReplaceRuleSet] to one book's titles and content.
///
/// The rules run in the frozen order. A pattern the engine cannot express or
/// an ordinary replacement error is reported and left out; a timed-out rule is
/// reported, disabled through [onRuleDisabled], and left out. JavaScript
/// replacement calls use the same per-rule deadline and cancellation signal as
/// the approved source runtime.
///
/// [content] is the single text entry of both reading paths, and it returns the
/// text it produced together with the script of the run ([ProcessedContent]).
/// The online reader consumes the text and nothing else; the local reader
/// consumes the script to translate its raw-file position exactly (ADR 0012:
/// one entry, no second evaluator).
class ContentProcessing {
  ContentProcessing({
    required this.rules,
    required this.bookName,
    this.script,
    this.convert = TextEngine.convertTo,
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
  /// Which one a reader wants is #27's choice
  /// (`lib/settings/reader_script.dart`); the conversion itself is ADR 0010's,
  /// and the frozen engine converts inside this same stage.
  ///
  /// A reader that changes the choice while a book is open sets this and runs
  /// the stage again, so the text is re-rendered without reopening the book.
  ConvertTarget? script;

  /// The conversion itself: the engine's reader target (ADR 0010), through
  /// `TextEngine.convertTo`.
  ///
  /// The default is the native call. A widget test injects a pure-Dart double
  /// because its binding cannot load the native library — the same seam reason
  /// [scriptRuntime] exists.
  final String Function(String text, ConvertTarget target) convert;

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

  /// Where a skipped rule is reported, as a message the page renders in its own
  /// language (#72); the rule's name is an argument, and the engine's own
  /// refusal or error text is another (a diagnostic, passed through as it is).
  /// Each rule is reported at most once per instance, so a chapter-by-chapter
  /// report cannot flood the reader.
  final void Function(StoreMessage message)? onNotice;

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

  /// The chapter title as the table-of-contents list shows it: the frozen
  /// `BookChapter.getDisplayTitle`'s own steps without the title rules, which
  /// the frozen list applies only when `AppConfig.tocUiUseReplace` is on
  /// (`ChapterListAdapter.kt:78`, default false). Synchronous, because a list
  /// row builds without awaiting.
  String listTitle(String title) =>
      converted(title.replaceAll(RegExp(r'[\r\n]'), ''));

  /// [text] in the reader's script, or as it is when no target is set.
  String converted(String text) {
    final target = script;
    return target == null ? text : convert(text, target);
  }

  /// The chapter body as the frozen reader reads it
  /// (`ContentProcessor.getContent(..., includeTitle = false)`), in the frozen
  /// order: the duplicate leading title, the optional re-segmentation, the
  /// conversion, the per-line trim the replace stage does, the content rules,
  /// and finally the frozen paragraph shaping whose joined result is the frozen
  /// `BookContent.toString()` the #17 boundary pins.
  ///
  /// The result is the text and the script of the run it took to produce it:
  /// [ProcessedContent.edits] names every range of [raw] the run rewrote, in
  /// [raw]'s own offsets. Outside those ranges the text is [raw]'s own, shifted
  /// by the length the rewritten ranges add or remove, so a position stored in
  /// the raw text translates exactly into the processed text and back.
  ///
  /// [includeTitle] is the frozen `includeTitle` argument: when true, the display
  /// title is prepended as its own line, which is where the frozen content stage
  /// puts it before the reader splits the body into paragraphs, and the shaping
  /// then leaves that first paragraph unindented. The title is not part of [raw],
  /// so the script carries it as an insertion at the run's start.
  Future<ProcessedContent> content(
    String raw, {
    required String chapterTitle,
    bool includeTitle = false,
  }) async {
    // The frozen guard: a source stage that produced nothing hands over the
    // literal text "null", which is not content and is not processed.
    if (raw == 'null') {
      return ProcessedContent(text: raw, edits: const <ContentEdit>[]);
    }
    final deduped = await _removeDuplicatedTitle(raw, chapterTitle);
    var text = deduped.text;
    var trace = _OffsetTrace.identity(raw.length).after(
      deduped.dropped == 0
          ? const <ContentEdit>[]
          : [ContentEdit(start: 0, end: deduped.dropped, length: 0)],
      text,
    );
    // The frozen `if (reSegment && book.getReSegment())`
    // (`ContentProcessor.kt:131-133`): after the duplicate-title removal, before
    // the conversion and the replace rules. It re-segments on the *raw* chapter
    // title, the one the title pattern above also used. Because it changes the
    // body before the reader computes its line offsets, enabling it for a book
    // moves that book's stored positions, exactly as the frozen reader's do
    // (see #47 for the local reader's offset model). The stage reflows
    // paragraphs rather than rewriting ranges, so its script is the whole text
    // as one rewritten range (the local reader passes the frozen default, off).
    if (useReSegment) {
      final next = reSegment(text, chapterTitle);
      trace = trace.after([
        ContentEdit(start: 0, end: text.length, length: next.length),
      ], next);
      text = next;
    }
    if (script != null) {
      final next = converted(text);
      trace = trace.after(_conversionEdits(text, next), next);
      text = next;
    }
    if (useReplaceRule) {
      // The replace stage trims every line before the rules see it.
      final trimmed = _trimLines(text);
      trace = trace.after(trimmed.edits, trimmed.text);
      text = trimmed.text;
      for (final rule in rules.contentRules) {
        if (rule.pattern.isEmpty) continue;
        final applied = await _apply(text, rule);
        if (applied == null) continue;
        trace = trace.after(applied.edits, applied.text);
        text = applied.text;
      }
    }
    if (includeTitle) {
      final title = await displayTitle(chapterTitle);
      final next = '$title\n$text';
      trace = trace.after([
        ContentEdit(start: 0, end: 0, length: title.length + 1),
      ], next);
      text = next;
    }
    final shaped = _shapeParagraphs(text, includeTitle: includeTitle);
    trace = trace.after(shaped.edits, shaped.text);
    return ProcessedContent(text: shaped.text, edits: trace.script());
  }

  Future<String> _titleWithRules(
    String title,
    List<ReplaceRule> source, {
    required bool convert,
  }) async {
    var text = title.replaceAll(RegExp(r'[\r\n]'), '');
    if (convert && script != null) text = converted(text);
    if (!useReplaceRule) return text;
    for (final rule in source) {
      if (rule.pattern.isEmpty) continue;
      final candidate = await _apply(text, rule);
      if (candidate != null && candidate.text.trim().isNotEmpty) {
        text = candidate.text;
      }
    }
    return text;
  }

  /// The frozen duplicated-leading-title removal (`ContentProcessor.kt:120-135`),
  /// with the length dropped from the front of the content.
  ///
  /// The first pattern is the raw chapter title with every whitespace run as
  /// `\s*` and the book's own name allowed as leading punctuation noise; when it
  /// does not match, the frozen reader retries with the title the **content**
  /// rules produce — a quirk: the content rules, and without conversion.
  Future<({String text, int dropped})> _removeDuplicatedTitle(
    String content,
    String chapterTitle,
  ) async {
    final rawTitle = RegExp(
      '$_leading${_javaTitlePattern(chapterTitle)}$_javaSpaceStar',
      unicode: true,
    ).firstMatch(content);
    if (rawTitle != null) {
      return (text: content.substring(rawTitle.end), dropped: rawTitle.end);
    }
    if (!useReplaceRule) return (text: content, dropped: 0);
    final processed = await _titleWithRules(
      chapterTitle,
      rules.contentRules,
      convert: false,
    );
    if (processed.isEmpty) return (text: content, dropped: 0);
    final retry = RegExp(
      '$_leading${_javaQuoted(processed)}$_javaSpaceStar',
      unicode: true,
    ).firstMatch(content);
    if (retry != null) {
      return (text: content.substring(retry.end), dropped: retry.end);
    }
    return (text: content, dropped: 0);
  }

  /// `^(\s|\p{P}|<quoted book name>)*` in the frozen reader's own words: Java's
  /// ASCII `\s` (which includes the space), Unicode punctuation, and the book's
  /// name quoted.
  String get _leading => '^($_javaSpaceClass|\\p{P}|${_javaQuoted(bookName)})*';

  /// One rule's rewrite: the text and the edits it made to it, or null when the
  /// rule was left out (unusable pattern, deadline, JavaScript failure or
  /// cancellation) and the text is unchanged.
  Future<({String text, List<ContentEdit> edits})?> _apply(
    String text,
    ReplaceRule rule,
  ) async {
    final translated = rule.isRegex ? translateJavaPattern(rule.pattern) : null;
    if (translated != null && !translated.isRunnable) {
      _reportOnce(
        rule,
        StoreMessage(StoreMessageCode.replaceRuleUnusable, <Object?>[
          rule.name,
          translated.refusal,
        ]),
      );
      return null;
    }
    if (!rule.isRegex) {
      // Kotlin's literal `String.replace`, which is what the frozen content path
      // uses for a non-regex rule — including a replacement that starts with
      // `@js:`, which the literal branch never interprets.
      return _replaceLiteral(text, rule.pattern, rule.replacement);
    }
    if (rule.replacement.startsWith('@js:')) {
      final outcome = await _applyJsUnderDeadline(text, rule, translated!);
      if (outcome.cancelled) return null;
      if (outcome.timedOut) {
        _reportOnce(rule, _ruleTimeout(rule));
        await onRuleDisabled?.call(rule);
        return null;
      }
      if (outcome.error != null) {
        _reportOnce(rule, _ruleFailed(rule, outcome.error!));
        return null;
      }
      return (text: outcome.text!, edits: outcome.edits!);
    }
    final outcome = await _applyUnderDeadline(text, rule, translated!);
    if (outcome.timedOut) {
      _reportOnce(rule, _ruleTimeout(rule));
      await onRuleDisabled?.call(rule);
      return null;
    }
    if (outcome.error != null) {
      _reportOnce(rule, _ruleFailed(rule, outcome.error!));
      return null;
    }
    return (text: outcome.text!, edits: outcome.edits!);
  }

  StoreMessage _ruleTimeout(ReplaceRule rule) => StoreMessage(
    StoreMessageCode.replaceRuleTimedOut,
    <Object?>[rule.name, _deadlineFor(rule).inMilliseconds],
  );

  StoreMessage _ruleFailed(ReplaceRule rule, String error) => StoreMessage(
    StoreMessageCode.replaceRuleFailed,
    <Object?>[rule.name, error],
  );

  void _reportOnce(ReplaceRule rule, StoreMessage message) {
    if (!_reported.add(rule.id)) return;
    onNotice?.call(message);
  }

  Duration _deadlineFor(ReplaceRule rule) => rule.timeoutMillisecond <= 0
      ? timeoutFallback
      : Duration(milliseconds: rule.timeoutMillisecond);

  /// Applies the frozen JavaScript replacement once per match. The stopwatch
  /// carries one rule deadline across all matches, matching the frozen worker
  /// that wraps the complete replacement pass in one timeout.
  ///
  /// The match enumeration, the capture access, the template parsing and the
  /// expanded buffer live in [_JsExpansionWorker]; this method only evaluates
  /// one script per match between two worker requests, so the reading isolate
  /// never runs the expansion. The text the capture references insert is
  /// counted against [_maxJsExpansionBytes] before any of it is built, and a
  /// rule that would pass it fails ordinarily, with its input and edits kept.
  Future<_Outcome> _applyJsUnderDeadline(
    String text,
    ReplaceRule rule,
    JavaPattern pattern,
  ) async {
    final runtime = scriptRuntime ?? InProcessSourceScriptRuntime();
    final script = rule.replacement.substring(4);
    final deadline = _deadlineFor(rule);
    final stopwatch = Stopwatch()..start();
    _JsExpansionWorker? worker;
    try {
      var remaining = deadline - stopwatch.elapsed;
      if (remaining <= Duration.zero) return const _Outcome.timeout();
      worker = await _JsExpansionWorker.start(
        pattern: pattern,
        text: text,
        maxInsertedBytes: _maxJsExpansionBytes,
        cancellation: cancellation,
      );
      // Every awaited boundary is followed by the same admission check: a
      // cancellation or an elapsed deadline that happened while waiting wins
      // over the reply that arrived, before that reply is interpreted or
      // committed.
      var stopped = _ruleStopped(stopwatch, deadline);
      if (stopped != null) return stopped;
      while (true) {
        remaining = deadline - stopwatch.elapsed;
        if (remaining <= Duration.zero) return const _Outcome.timeout();
        final next = await worker.ask(const <Object?>['next'], remaining);
        stopped = _ruleStopped(stopwatch, deadline);
        if (stopped != null) return stopped;
        if (next == null) return _jsWorkerStopped(timedOut: true);
        switch (next.first) {
          case 'match':
            if (next.length < 4 ||
                next[1] is! int ||
                next[2] is! int ||
                next[3] is! String) {
              return const _Outcome.error('替换进程返回了意外结果');
            }
            remaining = deadline - stopwatch.elapsed;
            if (remaining <= Duration.zero) return const _Outcome.timeout();
            final value = await runtime.evaluate(
              source: script,
              input: {'sourceKey': '', 'result': next[3] as String},
              timeout: remaining,
              cancellation: cancellation,
            );
            stopped = _ruleStopped(stopwatch, deadline);
            if (stopped != null) return stopped;
            remaining = deadline - stopwatch.elapsed;
            if (remaining <= Duration.zero) return const _Outcome.timeout();
            final expanded = await worker.ask(<Object?>[
              'expand',
              '$value',
            ], remaining);
            stopped = _ruleStopped(stopwatch, deadline);
            if (stopped != null) return stopped;
            if (expanded == null) return _jsWorkerStopped(timedOut: true);
            if (expanded.first == 'exit') {
              return _jsWorkerStopped(timedOut: false);
            }
            if (expanded.first == 'over') {
              return const _Outcome.error(_jsExpansionLimitMessage);
            }
            if (expanded.first == 'invalid') {
              return const _Outcome.error('替换里的分组引用不存在');
            }
            if (expanded.first != 'ok') {
              return _Outcome.error(
                '${expanded.length > 1 ? expanded[1] : expanded.first}',
              );
            }
            break;
          case 'done':
            if (next.length < 3 || next[1] is! String) {
              return const _Outcome.error('替换进程返回了意外结果');
            }
            return _Outcome.text(
              next[1] as String,
              edits: _replacementEdits(next[2]),
            );
          case 'error':
            return _Outcome.error('${next.length > 1 ? next[1] : next.first}');
          case 'exit':
            return _jsWorkerStopped(timedOut: false);
          default:
            return const _Outcome.error('替换进程返回了意外结果');
        }
      }
    } on SourceScriptError catch (error) {
      if (error.category == 'cancelled') return const _Outcome.cancelled();
      if (error.category == 'timeout') return const _Outcome.timeout();
      return _Outcome.error('$error');
    } on SourceRequestCancelled {
      return const _Outcome.cancelled();
    } catch (error) {
      if (cancellation?.isCancelled ?? false) return const _Outcome.cancelled();
      return _Outcome.error('$error');
    } finally {
      worker?.close();
    }
  }

  /// The rule's own elapsed deadline and the caller's cancellation, checked
  /// after every awaited boundary: a cancellation that fired while waiting wins
  /// over the reply that arrived, and an elapsed deadline wins over a reply
  /// that came back too late. Null means the rule may still proceed.
  _Outcome? _ruleStopped(Stopwatch stopwatch, Duration deadline) {
    if (cancellation?.isCancelled ?? false) return const _Outcome.cancelled();
    if (stopwatch.elapsed >= deadline) return const _Outcome.timeout();
    return null;
  }

  /// What a worker that stopped answering means: an abandoned operation is
  /// cancellation, an unanswered request is the rule's own deadline, and a
  /// worker that exited on its own is the existing unexpected-exit error.
  _Outcome _jsWorkerStopped({required bool timedOut}) {
    if (cancellation?.isCancelled ?? false) return const _Outcome.cancelled();
    return timedOut
        ? const _Outcome.timeout()
        : const _Outcome.error('替换进程意外退出');
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
          return _Outcome.text(
            '${message[1]}',
            edits: _replacementEdits(message.length > 2 ? message[2] : null),
          );
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

/// The trim the frozen replace stage does before the rules see the text: every
/// line trimmed from both ends (`ContentProcessor.kt:139-141`, `str.trim()`,
/// which Dart's own `String.trim` matches).
({String text, List<ContentEdit> edits}) _trimLines(String text) {
  final lines = text.split('\n');
  final edits = <ContentEdit>[];
  var cursor = 0;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.length != line.length) {
      if (trimmed.isEmpty) {
        edits.add(
          ContentEdit(start: cursor, end: cursor + line.length, length: 0),
        );
      } else {
        // The trimmed line's first occurrence in the line is its own position:
        // the line's first non-whitespace code unit cannot start `trimmed`
        // earlier, because that code unit would then be whitespace.
        final lead = line.indexOf(trimmed);
        edits.add(ContentEdit(start: cursor, end: cursor + lead, length: 0));
        edits.add(
          ContentEdit(
            start: cursor + lead + trimmed.length,
            end: cursor + line.length,
            length: 0,
          ),
        );
      }
    }
    cursor += line.length + 1;
  }
  return (text: lines.map((line) => line.trim()).join('\n'), edits: edits);
}

/// The conversion stage's edits.
///
/// The conversion tables live in the native library and do not report the
/// boundaries inside a line, so a line the conversion left the same length is
/// translated offset for offset — every table entry consumes as many code units
/// as it writes, so equal lengths mean positional alignment — and a line whose
/// converted form has another length is one rewritten range. A conversion that
/// moved the line structure itself is one rewritten range over the whole text.
List<ContentEdit> _conversionEdits(String before, String after) {
  if (before == after) return const <ContentEdit>[];
  final beforeLines = before.split('\n');
  final afterLines = after.split('\n');
  if (beforeLines.length != afterLines.length) {
    return [ContentEdit(start: 0, end: before.length, length: after.length)];
  }
  final edits = <ContentEdit>[];
  var cursor = 0;
  for (var index = 0; index < beforeLines.length; index++) {
    if (beforeLines[index].length != afterLines[index].length) {
      edits.add(
        ContentEdit(
          start: cursor,
          end: cursor + beforeLines[index].length,
          length: afterLines[index].length,
        ),
      );
    }
    cursor += beforeLines[index].length + 1;
  }
  return edits;
}

/// Kotlin's literal `String.replace`: every non-overlapping occurrence of
/// [pattern] replaced by [replacement] as written, and the edits that did it.
({String text, List<ContentEdit> edits}) _replaceLiteral(
  String text,
  String pattern,
  String replacement,
) {
  final buffer = StringBuffer();
  final edits = <ContentEdit>[];
  var cursor = 0;
  for (final match in pattern.allMatches(text)) {
    buffer.write(text.substring(cursor, match.start));
    buffer.write(replacement);
    edits.add(
      ContentEdit(
        start: match.start,
        end: match.end,
        length: replacement.length,
      ),
    );
    cursor = match.end;
  }
  buffer.write(text.substring(cursor));
  return (text: buffer.toString(), edits: edits);
}

/// The monotone map from the offsets of the text one stage is working on back to
/// the offsets of the text `content` was given.
///
/// The map is a list of cuts, each a pair of matching offsets. Between two cuts
/// either the two spaces advance together — the text was copied — or they do
/// not, and every offset in that range then resolves to the cut that opens it.
/// A stage hands its own rewrites to [after] as [ContentEdit]s in the offsets of
/// the text it was given; nothing here compares texts to guess at a
/// correspondence, so the map carries only what the stages actually did.
class _OffsetTrace {
  _OffsetTrace._(this._text, this._input);

  /// The identity over a text of [length] code units.
  factory _OffsetTrace.identity(int length) =>
      _OffsetTrace._([0, length], [0, length]);

  /// The cuts' offsets in the text the current stage is working on, ascending,
  /// from `0` to that text's length.
  final List<int> _text;

  /// The cuts' offsets in the text `content` was given, ascending, from `0` to
  /// that text's length.
  final List<int> _input;

  /// The offset of the given text that produced [textOffset]: exact where the
  /// text was copied, and where a run rewrote the text its range's first offset
  /// — the range is opaque, so every offset of it answers the same.
  int inputAt(int textOffset) {
    final at = _lastAtOrBefore(_text, textOffset);
    if (at == _text.length - 1 || textOffset == _text[at]) {
      return _input[at];
    }
    return _text[at + 1] - _text[at] == _input[at + 1] - _input[at]
        ? _input[at] + (textOffset - _text[at])
        : _input[at];
  }

  /// The trace after a stage turned this trace's text into [next] through
  /// [edits], which are ranges of the text this trace describes.
  _OffsetTrace after(List<ContentEdit> edits, String next) {
    if (edits.isEmpty) return this;
    // Where each edit's replacement starts and ends in the text the stage
    // produced, and how far the text has shifted by the end of each edit.
    final starts = List<int>.filled(edits.length, 0);
    final shifts = List<int>.filled(edits.length, 0);
    var shift = 0;
    for (var at = 0; at < edits.length; at++) {
      starts[at] = edits[at].start + shift;
      shift += edits[at].length - (edits[at].end - edits[at].start);
      shifts[at] = shift;
    }

    int indexAt(int offset, int Function(int) key) {
      var low = 0;
      var high = edits.length - 1;
      var found = -1;
      while (low <= high) {
        final middle = (low + high) >> 1;
        if (key(middle) <= offset) {
          found = middle;
          low = middle + 1;
        } else {
          high = middle - 1;
        }
      }
      return found;
    }

    // The stage's texts on the two sides of [offset]: an insertion that sits
    // exactly there leaves the offset before it on the left and after it on the
    // right, and both are cuts of the composed map.
    int nextOfBefore(int offset) {
      var at = indexAt(offset, (middle) => edits[middle].start);
      while (at >= 0 && edits[at].start >= offset) {
        at -= 1;
      }
      if (at < 0) return offset;
      return offset < edits[at].end ? starts[at] : offset + shifts[at];
    }

    int nextOfAfter(int offset) {
      final at = indexAt(offset, (middle) => edits[middle].start);
      if (at < 0) return offset;
      return offset < edits[at].end ? starts[at] : offset + shifts[at];
    }

    final cuts = <(int, int)>[];

    // The map can only change slope where the stage changed it (an edit's two
    // boundaries) or where this trace already did (its own cuts, carried into
    // the stage's text). A cut this trace made twice at one offset is a range
    // the input lost: its first cut is the text before that range and its last
    // the text after it, so each keeps the side it belongs to.
    for (var at = 0; at < _text.length; at++) {
      final first = at == 0 || _text[at - 1] != _text[at];
      final last = at == _text.length - 1 || _text[at + 1] != _text[at];
      if (first) cuts.add((nextOfBefore(_text[at]), _input[at]));
      if (last) cuts.add((nextOfAfter(_text[at]), _input[at]));
    }
    for (var at = 0; at < edits.length; at++) {
      cuts.add((starts[at], inputAt(edits[at].start)));
      cuts.add((starts[at] + edits[at].length, inputAt(edits[at].end)));
    }
    cuts.add((next.length, _input.last));
    cuts.sort((a, b) {
      final byText = a.$1.compareTo(b.$1);
      return byText != 0 ? byText : a.$2.compareTo(b.$2);
    });

    final text = <int>[];
    final input = <int>[];
    for (final (textOffset, inputOffset) in cuts) {
      if (text.isNotEmpty &&
          text.last == textOffset &&
          input.last == inputOffset) {
        continue;
      }
      assert(
        text.isEmpty || (textOffset >= text.last && inputOffset >= input.last),
        'the trace cuts stay ordered',
      );
      text.add(textOffset);
      input.add(inputOffset);
    }
    return _OffsetTrace._(text, input);
  }

  /// The run's script: one [ContentEdit] per rewritten range, in the offsets of
  /// the text `content` was given. Ranges that turn out to be inside a range
  /// already emitted (a later stage rewrote text an earlier one had generated)
  /// are absorbed into it: the outer range is opaque, so the map cannot tell the
  /// two apart anyway, and the absorbed text lengthens it.
  List<ContentEdit> script() {
    final edits = <ContentEdit>[];
    for (var at = 0; at + 1 < _text.length; at++) {
      final textSpan = _text[at + 1] - _text[at];
      final inputStart = _input[at];
      final inputEnd = _input[at + 1];
      if (edits.isNotEmpty && inputStart < edits.last.end) {
        final previous = edits.removeLast();
        edits.add(
          ContentEdit(
            start: previous.start,
            end: inputEnd > previous.end ? inputEnd : previous.end,
            length: previous.length + textSpan,
          ),
        );
        continue;
      }
      if (textSpan == inputEnd - inputStart) continue;
      if (edits.isNotEmpty && edits.last.end == inputStart) {
        final previous = edits.removeLast();
        edits.add(
          ContentEdit(
            start: previous.start,
            end: inputEnd,
            length: previous.length + textSpan,
          ),
        );
        continue;
      }
      edits.add(
        ContentEdit(start: inputStart, end: inputEnd, length: textSpan),
      );
    }
    assert(_ascending(edits), 'the script is ascending and disjoint');
    return edits;
  }

  /// The last index whose value in [stops] is at or before [offset].
  static int _lastAtOrBefore(List<int> stops, int offset) {
    var low = 0;
    var high = stops.length - 1;
    var found = 0;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (stops[middle] <= offset) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }
}

/// Whether the script's ranges are ascending and disjoint.
bool _ascending(List<ContentEdit> edits) {
  for (var at = 1; at < edits.length; at++) {
    if (edits[at].start < edits[at - 1].end) return false;
  }
  return true;
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
///
/// The returned edits describe it: the trims it cuts, the empty paragraphs it
/// drops with their separators, and the indents it inserts. A line separator it
/// keeps is the newline the line before it ends with, so an offset on a kept
/// newline translates exactly; a dropped line takes the separator before it with
/// it.
({String text, List<ContentEdit> edits}) _shapeParagraphs(
  String text, {
  required bool includeTitle,
}) {
  final out = StringBuffer();
  final edits = <ContentEdit>[];
  final lines = text.split('\n');
  var emitted = 0;
  var cursor = 0;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final paragraph = _trimFrozen(line);
    // The separator this line follows — the newline the line before it ends
    // with — survives as this paragraph's own separator; the shaping drops it
    // with the paragraph, or when no paragraph came before it.
    if (index > 0) {
      if (paragraph.isNotEmpty && emitted > 0) {
        out.write('\n');
      } else {
        edits.add(ContentEdit(start: cursor - 1, end: cursor, length: 0));
      }
    }
    if (paragraph.isEmpty) {
      if (line.isNotEmpty) {
        edits.add(
          ContentEdit(start: cursor, end: cursor + line.length, length: 0),
        );
      }
    } else {
      final lead = _frozenTrimStart(line);
      if (lead > 0) {
        edits.add(ContentEdit(start: cursor, end: cursor + lead, length: 0));
      }
      final indent = emitted == 0 && includeTitle ? '' : _paragraphIndent;
      if (indent.isNotEmpty) {
        edits.add(
          ContentEdit(
            start: cursor + lead,
            end: cursor + lead,
            length: indent.length,
          ),
        );
        out.write(indent);
      }
      out.write(paragraph);
      final trailing = cursor + line.length - lead - paragraph.length;
      if (trailing > cursor + lead) {
        edits.add(
          ContentEdit(start: trailing, end: cursor + line.length, length: 0),
        );
      }
      emitted += 1;
    }
    cursor += line.length + 1;
  }
  return (text: out.toString(), edits: edits);
}

/// The frozen `str.trim { it.code <= 0x20 || it == '　' }`: Java's control/space
/// range plus the ideographic space, both ends.
String _trimFrozen(String text) {
  final start = _frozenTrimStart(text);
  var end = text.length;
  while (end > start && _frozenCut(text.codeUnitAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

int _frozenTrimStart(String text) {
  var start = 0;
  while (start < text.length && _frozenCut(text.codeUnitAt(start))) {
    start++;
  }
  return start;
}

bool _frozenCut(int codeUnit) => codeUnit <= 0x20 || codeUnit == 0x3000;

/// The most UTF-8 bytes one regex `@js:` rule may insert through capture
/// references in one execution, cumulatively over its matches and repeated
/// references. The unchanged input and the template's literal characters are
/// not part of it, and the existing JavaScript result cap stays separate.
const _maxJsExpansionBytes = 8 * 1024 * 1024;

/// The ordinary own-rule failure a regex `@js:` rule reports when its capture
/// expansion would pass [_maxJsExpansionBytes].
const _jsExpansionLimitMessage = '替换展开超过 8 MiB 上限';

/// One rule execution's match and expansion worker.
///
/// The selected reference runs the whole replacement pass on a worker
/// (`RegexExtensions.kt:29-63`) and expands every script return against the
/// original `Matcher` state. Dart's `RegExp` cannot be interrupted, so this
/// worker owns the match enumeration, the capture access, the template parsing
/// and the expanded buffer, and the caller evaluates one script per match
/// between two requests: the reading isolate never runs the expansion, and the
/// approved JavaScript boundary stays where it is.
///
/// The worker keeps the original text and the original `RegExpMatch`es, so a
/// capture is read from its own match when a template asks for it — never
/// rematched from a substring, and never collected for a group no template
/// references. The text those references insert is counted against
/// [maxInsertedBytes] before any of it is built.
class _JsExpansionWorker {
  _JsExpansionWorker._(
    this._isolate,
    this._replies,
    SourceCancellation? cancellation,
  ) : _unlisten = cancellation?.listen(() {
        _isolate.kill(priority: Isolate.immediate);
      }) {
    _replies.listen(_onMessage);
    if (cancellation?.isCancelled ?? false) {
      _isolate.kill(priority: Isolate.immediate);
    }
  }

  /// Spawns the worker for one rule execution.
  static Future<_JsExpansionWorker> start({
    required JavaPattern pattern,
    required String text,
    required int maxInsertedBytes,
    SourceCancellation? cancellation,
  }) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_jsExpansionEntry, <Object?>[
      replies.sendPort,
      pattern.source,
      text,
      pattern.caseSensitive,
      pattern.multiLine,
      pattern.dotAll,
      pattern.unicode,
      maxInsertedBytes,
    ], onExit: replies.sendPort);
    return _JsExpansionWorker._(isolate, replies, cancellation);
  }

  final Isolate _isolate;
  final ReceivePort _replies;
  final void Function()? _unlisten;
  final Completer<SendPort?> _ready = Completer<SendPort?>();
  Completer<List<Object?>>? _pending;
  bool _exited = false;
  bool _closed = false;

  /// Sends one request and waits for its reply, or null when the worker did not
  /// answer within [timeout]. A worker that exited answers `['exit']`. The one
  /// [timeout] covers readiness and the reply together: the reply gets only
  /// what readiness left of it.
  Future<List<Object?>?> ask(List<Object?> request, Duration timeout) async {
    final stopwatch = Stopwatch()..start();
    final requests = await _ready.future.timeout(
      timeout,
      onTimeout: () => null,
    );
    if (requests == null) return _exited ? const <Object?>['exit'] : null;
    final left = timeout - stopwatch.elapsed;
    if (left <= Duration.zero) return null;
    final pending = Completer<List<Object?>>();
    _pending = pending;
    requests.send(request);
    final reply = await pending.future.timeout(
      left,
      onTimeout: () => const <Object?>[],
    );
    if (reply.isEmpty) {
      _pending = null;
      return _exited ? const <Object?>['exit'] : null;
    }
    return reply;
  }

  void _onMessage(Object? message) {
    if (!_ready.isCompleted) {
      if (message is SendPort) {
        _ready.complete(message);
      } else {
        _exited = true;
        _ready.complete(null);
      }
      return;
    }
    final pending = _pending;
    _pending = null;
    if (pending == null || pending.isCompleted) return;
    pending.complete(
      message is List ? message.cast<Object?>() : const <Object?>['exit'],
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _unlisten?.call();
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
  }
}

class _Outcome {
  const _Outcome.text(this.text, {required this.edits})
    : timedOut = false,
      cancelled = false,
      error = null;
  const _Outcome.timeout()
    : text = null,
      edits = null,
      timedOut = true,
      cancelled = false,
      error = null;
  const _Outcome.cancelled()
    : text = null,
      edits = null,
      timedOut = false,
      cancelled = true,
      error = null;
  const _Outcome.error(this.error)
    : text = null,
      edits = null,
      timedOut = false,
      cancelled = false;
  final String? text;

  /// The ranges of the rule's input the replacement rewrote, in that text's
  /// offsets — null whenever [text] is null.
  final List<ContentEdit>? edits;
  final bool timedOut;
  final bool cancelled;
  final String? error;
}

/// The match/expansion worker's entry point: it holds the original text and
/// the original matches, so match enumeration, capture access, template parsing
/// and the expanded buffer all run here, off the reading isolate.
void _jsExpansionEntry(List<Object?> args) {
  final replies = args[0] as SendPort;
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  final _JsExpansion expansion;
  try {
    expansion = _JsExpansion(
      RegExp(
        args[1] as String,
        caseSensitive: args[3] as bool,
        multiLine: args[4] as bool,
        dotAll: args[5] as bool,
        unicode: args[6] as bool,
      ),
      args[2] as String,
      args[7] as int,
    );
  } catch (error) {
    replies.send(<Object?>['error', '$error']);
    return;
  }
  requests.listen((message) {
    if (message is! List) {
      replies.send(const <Object?>['error', '替换进程收到意外请求']);
      return;
    }
    try {
      replies.send(expansion.handle(message.cast<Object?>()));
    } catch (error) {
      replies.send(<Object?>['error', '$error']);
    }
  });
}

/// One rule execution's matches and expanded buffer, inside the worker.
class _JsExpansion {
  _JsExpansion(this._regex, this._text, this._limit);

  final RegExp _regex;
  final String _text;
  final int _limit;
  final StringBuffer _buffer = StringBuffer();
  final List<List<Object?>> _edits = <List<Object?>>[];
  late final Iterator<RegExpMatch> _matches = _regex.allMatches(_text).iterator;
  RegExpMatch? _current;
  int _cursor = 0;
  int _inserted = 0;

  /// Answers one request: the next original match, or the expansion of one
  /// script return against the current one.
  List<Object?> handle(List<Object?> request) {
    if (request.isEmpty) {
      return const <Object?>['error', '替换进程收到意外请求'];
    }
    switch (request.first) {
      case 'next':
        return _next();
      case 'expand':
        if (request.length < 2 || request[1] is! String) {
          return const <Object?>['error', '替换进程收到意外请求'];
        }
        return _expand(request[1] as String);
      default:
        return const <Object?>['error', '替换进程收到意外请求'];
    }
  }

  List<Object?> _next() {
    if (!_matches.moveNext()) {
      _buffer.write(_text.substring(_cursor));
      return <Object?>['done', _buffer.toString(), _edits];
    }
    final match = _matches.current;
    _current = match;
    return <Object?>['match', match.start, match.end, match.group(0)!];
  }

  List<Object?> _expand(String template) {
    final match = _current;
    if (match == null) {
      return const <Object?>['error', '替换进程收到意外请求'];
    }
    // Count what the capture references would insert before building any of
    // it: the budget is the sum of their UTF-8 lengths over the whole
    // execution, and the template's literal characters are not part of it.
    // The walk stops at the reference that passes the remaining allowance, so
    // a rejected expansion costs no more than the bytes that rejected it and
    // no later capture is resolved.
    final resolved = <String, String?>{};
    final lengths = <String, int>{};
    var contribution = 0;
    final walk = _walkJsTemplate(template, match, (_) {}, (index, name) {
      final key = _jsCaptureKey(index, name);
      final length = lengths[key] ??= _utf8Length(
        _jsCaptureText(index, name, match, resolved),
        stopAbove: _limit - _inserted - contribution,
      );
      contribution += length;
      return _inserted + contribution <= _limit;
    });
    if (walk == _JsTemplateWalk.invalid) return const <Object?>['invalid'];
    if (walk == _JsTemplateWalk.stopped) return <Object?>['over', _limit];
    _inserted += contribution;
    _buffer.write(_text.substring(_cursor, match.start));
    final before = _buffer.length;
    _walkJsTemplate(template, match, _buffer.write, (index, name) {
      _buffer.write(_jsCaptureText(index, name, match, resolved) ?? '');
      return true;
    });
    _edits.add(<Object?>[match.start, match.end, _buffer.length - before]);
    _cursor = match.end;
    return const <Object?>['ok'];
  }
}

/// How one walk of a selected regex-JS return ended.
enum _JsTemplateWalk {
  /// Every reference is valid and the walk reached the end of the template.
  complete,

  /// A reference is not valid for the match.
  invalid,

  /// The capture callback asked to stop, because the remaining budget is gone.
  stopped,
}

/// Walks one selected regex-JS return the way the selected reference's
/// `quoteReplacementJs`/`appendReplacement` pair does: literal text, `$`-numeric
/// references taking the longest existing group prefix, and `${name}`
/// references. [literal] and [capture] see the pieces in template order; a
/// capture callback that returns false stops the walk, which is how a rejected
/// expansion stops resolving captures as soon as its budget is gone.
_JsTemplateWalk _walkJsTemplate(
  String replacement,
  RegExpMatch match,
  void Function(String literal) literal,
  bool Function(int? index, String? name) capture,
) {
  final text = StringBuffer();
  var i = 0;
  bool digit(int c) => c >= 48 && c <= 57;
  bool letter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  while (i < replacement.length) {
    if (replacement[i] != r'$') {
      text.write(replacement[i++]);
      continue;
    }
    i++;
    if (i == replacement.length) return _JsTemplateWalk.invalid;
    if (replacement[i] == '{') {
      final start = ++i;
      while (i < replacement.length &&
          (letter(replacement.codeUnitAt(i)) ||
              digit(replacement.codeUnitAt(i)))) {
        i++;
      }
      if (i == start ||
          !letter(replacement.codeUnitAt(start)) ||
          i == replacement.length ||
          replacement[i] != '}') {
        return _JsTemplateWalk.invalid;
      }
      final name = replacement.substring(start, i++);
      if (!match.groupNames.contains(name)) return _JsTemplateWalk.invalid;
      if (text.isNotEmpty) {
        literal(text.toString());
        text.clear();
      }
      if (!capture(null, name)) return _JsTemplateWalk.stopped;
      continue;
    }
    if (!digit(replacement.codeUnitAt(i))) return _JsTemplateWalk.invalid;
    var group = replacement.codeUnitAt(i++) - 48;
    if (group > match.groupCount) return _JsTemplateWalk.invalid;
    while (i < replacement.length && digit(replacement.codeUnitAt(i))) {
      final next = group * 10 + replacement.codeUnitAt(i) - 48;
      if (next > match.groupCount) break;
      group = next;
      i++;
    }
    if (text.isNotEmpty) {
      literal(text.toString());
      text.clear();
    }
    if (!capture(group, null)) return _JsTemplateWalk.stopped;
  }
  if (text.isNotEmpty) literal(text.toString());
  return _JsTemplateWalk.complete;
}

/// The key one capture reference is cached under for one match.
String _jsCaptureKey(int? index, String? name) =>
    name == null ? 'index:$index' : 'name:$name';

/// The text one capture reference inserts, read from the original match and
/// resolved at most once per match: an unmatched or nonparticipating group
/// inserts nothing.
String? _jsCaptureText(
  int? index,
  String? name,
  RegExpMatch match,
  Map<String, String?> resolved,
) {
  final key = _jsCaptureKey(index, name);
  if (resolved.containsKey(key)) return resolved[key];
  final text = name == null ? match.group(index!) : match.namedGroup(name);
  resolved[key] = text;
  return text;
}

/// The UTF-8 byte length of [text], counted without encoding it: a lone
/// surrogate counts as the replacement character's three bytes, as the
/// encoder's own length does. Stops as soon as the count passes [stopAbove],
/// which is all the caller needs to know when the remaining allowance is
/// smaller than the text.
int _utf8Length(String? text, {int stopAbove = -1}) {
  if (text == null) return 0;
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0xDC00 &&
        text.codeUnitAt(i + 1) <= 0xDFFF) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
    if (stopAbove >= 0 && bytes > stopAbove) return bytes;
  }
  return bytes;
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
    final edits = <List<Object?>>[];
    var cursor = 0;
    for (final match in regex.allMatches(text)) {
      buffer.write(text.substring(cursor, match.start));
      final expanded = expandJavaReplacement(replacement, match);
      if (expanded == null) {
        send.send(const <Object?>['error', '替换里的分组引用不存在']);
        return;
      }
      buffer.write(expanded);
      edits.add(<Object?>[match.start, match.end, expanded.length]);
      cursor = match.end;
    }
    buffer.write(text.substring(cursor));
    send.send(<Object?>['ok', buffer.toString(), edits]);
  } catch (error) {
    send.send(<Object?>['error', '$error']);
  }
}

/// The edits one regex replacement made, as the isolate reported them: `[start,
/// end, length]` per match.
List<ContentEdit> _replacementEdits(Object? reported) {
  if (reported is! List) return const <ContentEdit>[];
  final edits = <ContentEdit>[];
  for (final entry in reported) {
    if (entry is! List ||
        entry.length != 3 ||
        entry[0] is! int ||
        entry[1] is! int ||
        entry[2] is! int) {
      return const <ContentEdit>[];
    }
    edits.add(
      ContentEdit(
        start: entry[0] as int,
        end: entry[1] as int,
        length: entry[2] as int,
      ),
    );
  }
  return edits;
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
