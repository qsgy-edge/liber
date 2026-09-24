import '../domain/store_message.dart';
import 'app_localizations.dart';

/// The interface's words for a message the store or the source layer produced
/// (#72).
///
/// `StoreMessage` carries a code and the values its copy's placeholders take;
/// this is the one place the two meet, and the switch is exhaustive on purpose —
/// a new [StoreMessageCode] does not compile until its copy is written here.
///
/// The arguments are read positionally and cast to the type their ARB
/// placeholder declares (`lib/l10n/app_zh.arb` is the template): a `String`
/// placeholder takes `arguments[0] as String`, an `int` one
/// `arguments[0] as int`. The store writes them in the order the copy uses, so
/// the call below is also the record of what each code carries.
extension StoreMessageText on StoreMessage {
  String text(AppLocalizations l10n) => switch (code) {
    StoreMessageCode.literalCopy => l10n.literalCopy(literalText),

    StoreMessageCode.legacyOnlineReadingNotImported =>
      l10n.legacyOnlineReadingNotImported(arguments[0] as String),
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
      arguments[0] as int,
    ),
    StoreMessageCode.legacyMigrationStateNotParsed =>
      l10n.legacyMigrationStateNotParsed,
    StoreMessageCode.legacyMigrationNetworkBookWithoutUrl =>
      l10n.legacyMigrationNetworkBookWithoutUrl,
    StoreMessageCode.legacyImportSummary => l10n.legacyImportSummary(
      arguments[0] as int,
      arguments[1] as int,
      arguments[2] as int,
      arguments[3] as int,
      arguments[4] as int,
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
      arguments[0] as int,
    ),
    StoreMessageCode.backupAbsentMember => l10n.backupAbsentMember(
      arguments[0] as String,
    ),
    StoreMessageCode.backupUnreadMembers => l10n.backupUnreadMembers(
      arguments[0] as int,
      arguments[1] as String,
    ),
    StoreMessageCode.backupInvalidSources => l10n.backupInvalidSources(
      arguments[0] as int,
    ),
    StoreMessageCode.backupInvalidGroups => l10n.backupInvalidGroups(
      arguments[0] as int,
    ),
    StoreMessageCode.backupInvalidBooks => l10n.backupInvalidBooks(
      arguments[0] as int,
    ),
    StoreMessageCode.backupConflictingSources => l10n.backupConflictingSources(
      arguments[0] as int,
    ),
    StoreMessageCode.backupDuplicateBooks => l10n.backupDuplicateBooks(
      arguments[0] as int,
    ),
    StoreMessageCode.backupSystemGroups => l10n.backupSystemGroups(
      arguments[0] as int,
    ),
    StoreMessageCode.backupUnmatchedMasks => l10n.backupUnmatchedMasks(
      arguments[0] as int,
    ),
    StoreMessageCode.backupUnreadBooks => l10n.backupUnreadBooks(
      arguments[0] as int,
    ),
    StoreMessageCode.backupNonTextSources => l10n.backupNonTextSources(
      arguments[0] as int,
    ),
    StoreMessageCode.backupDroppedCovers => l10n.backupDroppedCovers(
      arguments[0] as int,
    ),
    StoreMessageCode.backupDroppedEntries => l10n.backupDroppedEntries(
      arguments[0] as int,
    ),
    StoreMessageCode.backupProgressChapterNameDropped =>
      l10n.backupProgressChapterNameDropped,
    StoreMessageCode.backupNoSourceMember => l10n.backupNoSourceMember,
    StoreMessageCode.backupNoGroupMember => l10n.backupNoGroupMember,

    StoreMessageCode.replaceRuleUnusable => l10n.replaceRuleUnusable(
      arguments[0] as String,
      arguments[1] as String,
    ),
    StoreMessageCode.replaceRuleTimedOut => l10n.replaceRuleTimedOut(
      arguments[0] as String,
      arguments[1] as int,
    ),
    StoreMessageCode.replaceRuleFailed => l10n.replaceRuleFailed(
      arguments[0] as String,
      arguments[1] as String,
    ),

    StoreMessageCode.runSearching => l10n.runSearching,
    StoreMessageCode.runReading => l10n.runReading(arguments[0] as String),
    StoreMessageCode.runReadingToc => l10n.runReadingToc,
    StoreMessageCode.runJsonFirstChapterDone => l10n.runJsonFirstChapterDone,
    StoreMessageCode.runFailed => l10n.runFailed(
      arguments[0] as String,
      arguments[1] as String,
    ),
    StoreMessageCode.runControlledSearch => l10n.runControlledSearch,
    StoreMessageCode.runControlledBookInfo => l10n.runControlledBookInfo,
    StoreMessageCode.runControlledToc => l10n.runControlledToc,
    StoreMessageCode.runControlledContent => l10n.runControlledContent,
    StoreMessageCode.runControlledCompleted => l10n.runControlledCompleted,
  };
}
