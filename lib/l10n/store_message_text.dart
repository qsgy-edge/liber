import '../domain/contracts.dart' show BookSourceStage;
import '../domain/store_message.dart';
import 'app_localizations.dart';

/// The interface's words for a message the store or the source layer produced
/// (#72).
///
/// `StoreMessage` carries a code and the values its copy's placeholders take;
/// this is the one place the two meet, and the switch is exhaustive on purpose —
/// a new [StoreMessageCode] does not compile until its copy is written here.
///
/// The arguments are read positionally through [_string] and [_int], which is
/// also the record of what each code carries: a `String` placeholder takes
/// `_string(0)`, an `int` one `_int(0)`, and the store writes them in the order
/// the copy's placeholders use (`lib/l10n/app_zh.arb` is the template).
extension StoreMessageText on StoreMessage {
  String text(AppLocalizations l10n) => switch (code) {
    StoreMessageCode.literalCopy => l10n.literalCopy(literalText),

    StoreMessageCode.legacyOnlineReadingNotImported =>
      l10n.legacyOnlineReadingNotImported(_string(0)),
    StoreMessageCode.legacyOnlineReadingRecordWithoutSourceUrl =>
      l10n.legacyOnlineReadingRecordWithoutSourceUrl,
    StoreMessageCode.legacyOnlineReadingLastReadPointer =>
      l10n.legacyOnlineReadingLastReadPointer,
    StoreMessageCode.legacyLocalBooksNotParsed =>
      l10n.legacyLocalBooksNotParsed,
    StoreMessageCode.legacyLocalBooksWithoutRoot =>
      l10n.legacyLocalBooksWithoutRoot,
    StoreMessageCode.legacyLocalBookBytesExcluded =>
      l10n.legacyLocalBookBytesExcluded,
    StoreMessageCode.legacyLocalFilesMissing => l10n.legacyLocalFilesMissing(
      _int(0),
    ),
    StoreMessageCode.legacyMigrationStateNotParsed =>
      l10n.legacyMigrationStateNotParsed,
    StoreMessageCode.legacyMigrationNetworkBookWithoutUrl =>
      l10n.legacyMigrationNetworkBookWithoutUrl,
    StoreMessageCode.legacyImportSummary => l10n.legacyImportSummary(
      _int(0),
      _int(1),
      _int(2),
      _int(3),
      _int(4),
    ),

    StoreMessageCode.backupEnvelopeExcludedFamilies =>
      l10n.backupEnvelopeExcludedFamilies,
    StoreMessageCode.backupEnvelopeNoSources => l10n.backupEnvelopeNoSources,
    StoreMessageCode.backupEnvelopeNoBooks => l10n.backupEnvelopeNoBooks,
    StoreMessageCode.backupEnvelopeNoProgress => l10n.backupEnvelopeNoProgress,
    StoreMessageCode.backupEnvelopeSourceWithoutUrlOrName =>
      l10n.backupEnvelopeSourceWithoutUrlOrName,
    StoreMessageCode.backupEnvelopeBookWithoutKey =>
      l10n.backupEnvelopeBookWithoutKey,

    StoreMessageCode.backupExcludedCookies => l10n.backupExcludedCookies,
    StoreMessageCode.backupExcludedCache => l10n.backupExcludedCache,
    StoreMessageCode.backupExcludedChapters => l10n.backupExcludedChapters,
    StoreMessageCode.backupExcludedDownloads => l10n.backupExcludedDownloads,
    StoreMessageCode.backupExcludedLocalBytes => l10n.backupExcludedLocalBytes,
    StoreMessageCode.backupAndroidPreferences => l10n.backupAndroidPreferences(
      _int(0),
    ),
    StoreMessageCode.backupAbsentMember => l10n.backupAbsentMember(_string(0)),
    StoreMessageCode.backupUnreadMembers => l10n.backupUnreadMembers(
      _int(0),
      _string(1),
    ),
    StoreMessageCode.backupInvalidSources => l10n.backupInvalidSources(_int(0)),
    StoreMessageCode.backupInvalidGroups => l10n.backupInvalidGroups(_int(0)),
    StoreMessageCode.backupInvalidBooks => l10n.backupInvalidBooks(_int(0)),
    StoreMessageCode.backupConflictingSources => l10n.backupConflictingSources(
      _int(0),
    ),
    StoreMessageCode.backupDuplicateBooks => l10n.backupDuplicateBooks(_int(0)),
    StoreMessageCode.backupSystemGroups => l10n.backupSystemGroups(_int(0)),
    StoreMessageCode.backupUnmatchedMasks => l10n.backupUnmatchedMasks(_int(0)),
    StoreMessageCode.backupUnreadBooks => l10n.backupUnreadBooks(_int(0)),
    StoreMessageCode.backupNonTextSources => l10n.backupNonTextSources(_int(0)),
    StoreMessageCode.backupDroppedCovers => l10n.backupDroppedCovers(_int(0)),
    StoreMessageCode.backupDroppedEntries => l10n.backupDroppedEntries(_int(0)),
    StoreMessageCode.backupProgressChapterNameDropped =>
      l10n.backupProgressChapterNameDropped,
    StoreMessageCode.backupNoSourceMember => l10n.backupNoSourceMember,
    StoreMessageCode.backupNoGroupMember => l10n.backupNoGroupMember,

    StoreMessageCode.replaceRuleUnusable => l10n.replaceRuleUnusable(
      _string(0),
      _string(1),
    ),
    StoreMessageCode.replaceRuleTimedOut => l10n.replaceRuleTimedOut(
      _string(0),
      _int(1),
    ),
    StoreMessageCode.replaceRuleFailed => l10n.replaceRuleFailed(
      _string(0),
      _string(1),
    ),

    StoreMessageCode.runSearching => l10n.runSearching,
    StoreMessageCode.runReading => l10n.runReading(_string(0)),
    StoreMessageCode.runReadingToc => l10n.runReadingToc,
    StoreMessageCode.runJsonFirstChapterDone => l10n.runJsonFirstChapterDone,
    // The stage's own word, not the identifier `BookSourceStage.name` spells:
    // the card that shows this line lists the four stages with these keys.
    StoreMessageCode.runFailed => l10n.runFailed(
      _stageWord(l10n, _string(0)),
      _string(1),
    ),
    StoreMessageCode.runControlledSearch => l10n.runControlledSearch,
    StoreMessageCode.runControlledBookInfo => l10n.runControlledBookInfo,
    StoreMessageCode.runControlledToc => l10n.runControlledToc,
    StoreMessageCode.runControlledContent => l10n.runControlledContent,
    StoreMessageCode.runControlledCompleted => l10n.runControlledCompleted,
  };

  /// The argument at [index] as the copy's `String` placeholder declares it.
  ///
  /// A stored marker whose arguments are short, or of another type, still
  /// renders: the value the entry does carry is stringified and one it lacks is
  /// empty. A hand-edited entry, or one a newer build wrote, must not throw
  /// while the page that shows the report is building.
  String _string(int index) =>
      index < arguments.length ? '${arguments[index]}' : '';

  /// The argument at [index] as the copy's `int` placeholder declares it: a
  /// number, a number stored as text, or 0 when the entry carries neither.
  int _int(int index) {
    final value = index < arguments.length ? arguments[index] : null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}') ?? 0;
  }

  /// The interface's word for the stage a run failed in.
  ///
  /// A stage name this build cannot place keeps its identifier: the four stages
  /// `JsonSourcePipeline.run` walks are the ones the card lists, so anything
  /// else can only come from a build with a stage this one does not have.
  String _stageWord(AppLocalizations l10n, String name) =>
      switch (_stageOf(name)) {
        BookSourceStage.search => l10n.stageSearch,
        BookSourceStage.bookInfo => l10n.stageBookInfo,
        BookSourceStage.tableOfContents => l10n.stageTableOfContents,
        BookSourceStage.content => l10n.stageContent,
        _ => name,
      };

  static BookSourceStage? _stageOf(String name) {
    for (final stage in BookSourceStage.values) {
      if (stage.name == name) return stage;
    }
    return null;
  }
}
