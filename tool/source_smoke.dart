// Real-source smoke tool (#95).
//
// While taking two of the operator's real sources from failure to content, the
// controller wrote the same throwaway probe three times: read one source record
// out of the operator's own backup (read-only), run this product's pipeline
// against the live site for one book, and print what each stage produced. This
// is that probe as a tool, so the next real-source report costs one command:
//
//   dart run tool/source_smoke.dart \
//     --backup <legado-backup.zip|bookSource.json> \
//     --source <bookSourceUrl> \
//     --book <bookUrl>
//
// It selects one record out of the backup through the shared reader
// (`readSourceBackup`, `tool/source_usage.dart`), runs `details` -> `toc` ->
// one `chapter` through `openBookSourcePipeline` over `HttpSourceTransport`
// (no store: both pipelines build an in-memory host surface when none is
// given), and prints, per stage, the addresses it requested, the details'
// title and author, the chapter count and the first chapter's name and URL, and
// the first chapter's text length and first line — counts, titles and short
// prefixes, never a body.
//
// Every address and every failure message is redacted: a URL's query values are
// replaced, so a token a URL carries never reaches the output. The tool never
// reads out the source's `header` values or the session's cookie jar, and holds
// no store that could carry them across runs.
//
// Every stage that sends a request decodes its response body through the Rust
// text engine, so a live run always loads the fjs native library. When the
// environment does not name one (`LIBER_FJS_LIBRARY`), the standard build
// output is used; a stage that needs the library and cannot have it fails by
// name at that stage.
//
// Exit code 0 on success; 2 for a usage error; 1 for a failed read or stage,
// with the stage, the address and the message on stderr.
import 'dart:io';

import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_http_uri.dart';

import 'source_usage.dart';

/// The line a redacted value prints as.
const redactedValue = '<redacted>';

/// The longest a title, a name or a first line may be in the output.
const smokeFieldLimit = 120;

/// The usage line the tool prints on a bad command line.
const smokeUsage =
    'dart run tool/source_smoke.dart --backup <backup.zip|bookSource.json> '
    '--source <bookSourceUrl> --book <bookUrl>';

/// A URL query value: the `=…` after a `?` or a `&`.
final RegExp _queryValue = RegExp(r'([?&][^=&?#]*=)[^&?#]*');

/// [text] with every URL query value replaced, so no token a URL carries is
/// printed.
String redactQueryValues(String text) =>
    text.replaceAllMapped(_queryValue, (match) => '${match[1]}$redactedValue');

/// [value] as a bounded prefix.
String boundedSmokeField(String value, [int limit = smokeFieldLimit]) =>
    value.length <= limit ? value : '${value.substring(0, limit)}…';

/// The first line of [text], trimmed and bounded.
String firstLineOf(String text) {
  final end = text.indexOf('\n');
  return boundedSmokeField((end < 0 ? text : text.substring(0, end)).trim());
}

/// One failed run, named by its reason.
class SourceSmokeFailure implements Exception {
  const SourceSmokeFailure({
    required this.reason,
    required this.message,
    this.stage,
    this.address,
  });

  /// The name the failure is reported under, e.g. `details-failed`.
  final String reason;

  /// The message the stage raised, with its URL query values redacted.
  final String message;

  /// The stage the failure belongs to, when it belongs to one.
  final String? stage;

  /// The address the stage was reading, when it has one.
  final String? address;

  @override
  String toString() => 'source smoke failed: $reason — $message';
}

/// The failure as the tool renders it: the reason, the message, and the stage
/// and address when it has them.
String renderSmokeFailure(SourceSmokeFailure failure) => <String>[
  'source smoke failed: ${failure.reason}',
  '  message: ${failure.message}',
  if (failure.stage != null) '  stage: ${failure.stage}',
  if (failure.address != null) '  address: ${failure.address}',
].join('\n');

/// The parsed command line.
class SmokeArguments {
  const SmokeArguments({
    required this.backup,
    required this.source,
    required this.book,
  });

  final String backup;
  final String source;
  final String book;
}

/// Reads `--backup`, `--source` and `--book`; throws a [FormatException] for a
/// missing flag or a flag with no value.
SmokeArguments parseSmokeArguments(List<String> args) {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    if (index < 0) return null;
    if (index + 1 >= args.length) {
      throw FormatException('$name needs a value');
    }
    return args[index + 1];
  }

  final backup = valueOf('--backup');
  final source = valueOf('--source');
  final book = valueOf('--book');
  if (backup == null || source == null || book == null) {
    throw const FormatException(
      '--backup, --source and --book are all required',
    );
  }
  return SmokeArguments(backup: backup, source: source, book: book);
}

/// What one smoke run produced: per stage, the addresses it requested and the
/// counts and short fields it is reported by. Never a body.
class SourceSmokeReport {
  const SourceSmokeReport({
    required this.backup,
    required this.sourceAddress,
    required this.bookAddress,
    required this.json,
    required this.detailsRequests,
    required this.detailsTitle,
    required this.detailsAuthor,
    required this.tocRequests,
    required this.chapters,
    required this.firstChapterName,
    required this.firstChapterUrl,
    required this.chapterRequests,
    required this.chapterLength,
    required this.chapterFirstLine,
  });

  /// The backup the record was read from.
  final SourceBackup backup;

  /// The matched record's identity, with its query values redacted.
  final String sourceAddress;

  /// The book the run followed, with its query values redacted.
  final String bookAddress;

  /// Whether the record selected the JSON pipeline.
  final bool json;

  /// The `bookInfo` requests the details stage made, in order, redacted.
  final List<String> detailsRequests;

  final String detailsTitle;
  final String detailsAuthor;

  /// The `tableOfContents` requests the toc stage made, in order, redacted.
  final List<String> tocRequests;

  /// How many chapters the table of contents resolved.
  final int chapters;

  final String firstChapterName;

  /// The first chapter's address, with its query values redacted.
  final String firstChapterUrl;

  /// The `content` requests the chapter stage made, in order, redacted.
  final List<String> chapterRequests;

  final int chapterLength;

  /// The chapter text's first line, bounded and redacted.
  final String chapterFirstLine;
}

/// [report] as the tool's text: counts, titles and short prefixes only.
String renderSmokeReport(SourceSmokeReport report) => <String>[
  'real-source smoke — details → toc → first chapter, over the live site; '
      'counts, titles and short prefixes only',
  ...sourceBackupLines(report.backup),
  'source: ${report.sourceAddress}',
  'book: ${report.bookAddress}',
  'pipeline: ${report.json ? 'json' : 'html'}',
  '',
  'details',
  '  requests: ${report.detailsRequests.length}',
  for (final address in report.detailsRequests) '    $address',
  '  title: ${report.detailsTitle}',
  '  author: ${report.detailsAuthor}',
  '',
  'toc',
  '  requests: ${report.tocRequests.length}',
  for (final address in report.tocRequests) '    $address',
  '  chapters: ${report.chapters}',
  '  first chapter: ${report.firstChapterName}',
  '  first chapter url: ${report.firstChapterUrl}',
  '',
  'chapter',
  '  requests: ${report.chapterRequests.length}',
  for (final address in report.chapterRequests) '    $address',
  '  length: ${report.chapterLength} characters',
  '  first line: ${report.chapterFirstLine}',
  '',
].join('\n');

/// Runs one smoke: [source]'s details, toc and first chapter for [bookUrl],
/// through [openBookSourcePipeline] over `HttpSourceTransport`.
///
/// Throws a [SourceSmokeFailure] naming the stage that failed (its reason is
/// `<stage>-failed`) or the reason the run could not start (`toc-empty`).
Future<SourceSmokeReport> runSourceSmoke({
  required SourceBackup backup,
  required Map<String, dynamic> source,
  required String bookUrl,
}) async {
  await _initNativeLibrary();
  final pipeline = openBookSourcePipeline(source, HttpSourceTransport());
  try {
    return await _runSmoke(pipeline, backup, source, bookUrl);
  } finally {
    pipeline.cancel();
  }
}

Future<SourceSmokeReport> _runSmoke(
  BookSourcePipeline pipeline,
  SourceBackup backup,
  Map<String, dynamic> source,
  String bookUrl,
) async {
  final hit = HtmlBook(url: SourceHttpUri.parse(bookUrl), title: '');
  var from = pipeline.trace.length;
  final HtmlBook book;
  final List<SourceChapter> chapters;
  try {
    (book, chapters) = await pipeline.details(hit);
  } on Object catch (error) {
    throw _stageFailure(pipeline, 'details', error);
  }
  final detailsRequests = _stageRequests(
    pipeline.trace.skip(from),
    BookSourceStage.bookInfo,
  );
  final tocRequests = _stageRequests(
    pipeline.trace.skip(from),
    BookSourceStage.tableOfContents,
  );
  if (chapters.isEmpty) {
    throw SourceSmokeFailure(
      reason: 'toc-empty',
      stage: 'toc',
      address: tocRequests.isEmpty ? null : tocRequests.last,
      message: 'the table of contents resolved no chapters',
    );
  }

  final firstChapter = chapters.first;
  // The reader's next-chapter lookup (`OnlineReaderPage._open`): the chapter
  // after this one, or this chapter itself when it is the last, so a
  // `nextContentUrl` walk stops before fetching another chapter.
  final nextChapterUrl = chapters.length > 1
      ? '${chapters[1].url}'
      : '${firstChapter.url}';
  from = pipeline.trace.length;
  final HtmlChapterBody body;
  try {
    body = await pipeline.chapter(
      firstChapter,
      book: book,
      nextChapterUrl: nextChapterUrl,
    );
  } on Object catch (error) {
    throw _stageFailure(pipeline, 'chapter', error);
  }

  return SourceSmokeReport(
    backup: backup,
    sourceAddress: redactQueryValues('${source['bookSourceUrl']}'),
    bookAddress: redactQueryValues(bookUrl),
    json: isJsonRuleSource(source),
    detailsRequests: detailsRequests,
    detailsTitle: boundedSmokeField(book.title),
    detailsAuthor: boundedSmokeField(book.author),
    tocRequests: tocRequests,
    chapters: chapters.length,
    firstChapterName: boundedSmokeField(firstChapter.name),
    firstChapterUrl: redactQueryValues('${firstChapter.url}'),
    chapterRequests: _stageRequests(
      pipeline.trace.skip(from),
      BookSourceStage.content,
    ),
    chapterLength: body.text.length,
    chapterFirstLine: redactQueryValues(firstLineOf(body.text)),
  );
}

/// The addresses the skipped trace entries requested for [stage], in order.
List<String> _stageRequests(
  Iterable<BookSourceTraceEntry> trace,
  BookSourceStage stage,
) => <String>[
  for (final entry in trace)
    if (entry.stage == stage) redactQueryValues(entry.path),
];

/// One stage failure, named by the stage its last request belongs to.
SourceSmokeFailure _stageFailure(
  BookSourcePipeline pipeline,
  String fallbackStage,
  Object error,
) {
  final last = pipeline.trace.isEmpty ? null : pipeline.trace.last;
  final stage = switch (last?.stage) {
    BookSourceStage.bookInfo => 'details',
    BookSourceStage.tableOfContents => 'toc',
    BookSourceStage.content => 'chapter',
    _ => fallbackStage,
  };
  return SourceSmokeFailure(
    reason: '$stage-failed',
    stage: stage,
    address: last == null ? null : redactQueryValues(last.path),
    message: redactQueryValues('$error'),
  );
}

/// The record whose identity is [sourceUrl], or a `source-not-found` failure.
Map<String, dynamic> findSmokeSource(SourceBackup backup, String sourceUrl) {
  for (final source in backup.sources) {
    if (source['bookSourceUrl'] == sourceUrl) return source;
  }
  throw SourceSmokeFailure(
    reason: 'source-not-found',
    message:
        'the backup has no record with this bookSourceUrl '
        '(${redactQueryValues(sourceUrl)})',
  );
}

/// The tool's command line, returning the exit code instead of setting it.
///
/// [out] and [err] stand in for the process streams so a test can read what a
/// run prints.
Future<int> runSmokeCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;

  final SmokeArguments parsed;
  try {
    parsed = parseSmokeArguments(args);
  } on FormatException catch (error) {
    errors
      ..writeln('usage: $smokeUsage')
      ..writeln(error.message);
    return 2;
  }

  final SourceBackup backup;
  final Map<String, dynamic> source;
  try {
    backup = readSourceBackup(parsed.backup);
    source = findSmokeSource(backup, parsed.source);
  } on SourceSmokeFailure catch (failure) {
    errors.writeln(renderSmokeFailure(failure));
    return 1;
  } on Object catch (error) {
    errors.writeln(
      renderSmokeFailure(
        SourceSmokeFailure(
          reason: 'backup-unreadable',
          message: redactQueryValues('$error'),
        ),
      ),
    );
    return 1;
  }

  try {
    final report = await runSourceSmoke(
      backup: backup,
      source: source,
      bookUrl: parsed.book,
    );
    output.write(renderSmokeReport(report));
    return 0;
  } on SourceSmokeFailure catch (failure) {
    errors.writeln(renderSmokeFailure(failure));
    return 1;
  } on Object catch (error) {
    errors.writeln(
      renderSmokeFailure(
        SourceSmokeFailure(
          reason: 'run-failed',
          message: redactQueryValues('$error'),
        ),
      ),
    );
    return 1;
  }
}

Future<void> main(List<String> args) async {
  exitCode = await runSmokeCli(args);
}

/// Initializes the shared native library, best-effort.
///
/// Every stage that sends a request decodes its response through the Rust text
/// engine, so a live run always needs this; a library that cannot be resolved
/// is left for the failing stage to name, rather than refusing every run.
Future<void> _initNativeLibrary() async {
  final library = _resolveNativeLibrary();
  if (library == null) return;
  try {
    await NativeLibrary.initialize(libraryPath: library);
  } on Object {
    // A stage that needs the library will raise its own named failure.
  }
}

/// The fjs native library the app loads: `LIBER_FJS_LIBRARY` when set, else the
/// standard build output, else null.
String? _resolveNativeLibrary() {
  final fromEnvironment = Platform.environment['LIBER_FJS_LIBRARY'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    return fromEnvironment;
  }
  final stem = Platform.isWindows
      ? 'fjs.dll'
      : Platform.isMacOS
      ? 'libfjs.dylib'
      : 'libfjs.so';
  final bundle = Platform.isWindows
      ? 'build/windows/x64/runner/Debug'
      : Platform.isLinux
      ? 'build/linux/x64/debug/bundle/lib'
      : 'build/macos/Build/Products/Debug';
  final candidates = <String>[
    '$bundle/$stem',
    'packages/fjs/libfjs/target/debug/$stem',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
