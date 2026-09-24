/// One user-visible message the store or the source layer produced (#72).
///
/// The store layer has no `BuildContext` and may not depend on the widget layer,
/// so it cannot produce the interface's words. It produces a **code plus the
/// arguments the copy's placeholders take** instead, and the page renders it
/// through `AppLocalizations` (`StoreMessageText.text`,
/// `lib/l10n/store_message_text.dart` — where each code's arguments are named).
///
/// The code is an enum rather than a string so that renderer is an exhaustive
/// switch: a new code does not compile until its copy is written, and a code
/// that lost its copy cannot fall through to a blank line.
///
/// Diagnostics do not travel this way: a thrown error's text, a source log line
/// and an internal `toString()` stay as they are, in whatever words the code
/// that raised them used. A page that shows one of those beside its own words
/// passes it as an argument, as `chapterLoadFailed('$e')` does.
class StoreMessage {
  const StoreMessage(this.code, [this.arguments = const <Object?>[]]);

  /// A message whose whole text is its own copy.
  ///
  /// This is what an entry written before this seam existed means: a
  /// `legacy_import.v1` marker already in a space holds bare strings, and the
  /// one under a [StoreMessageCode.literalCopy] code is rendered verbatim
  /// rather than dropped.
  factory StoreMessage.literal(String text) =>
      StoreMessage(StoreMessageCode.literalCopy, <Object?>[text]);

  final StoreMessageCode code;

  /// The values the copy's placeholders take, in the order the code documents.
  /// `String` and `int` are the only types any code carries, because they are
  /// what an ARB placeholder and a JSON round trip both hold.
  final List<Object?> arguments;

  /// Reads one entry of a stored report: the object this build writes, or the
  /// bare string a build before #72 wrote.
  ///
  /// A code name this build does not know — a report a newer build wrote — is
  /// rendered verbatim rather than dropped, so a space stays readable after a
  /// downgrade.
  factory StoreMessage.fromJson(Object? json) {
    if (json is Map) {
      final name = '${json['code'] ?? ''}';
      final code = StoreMessageCode.bySlug(name);
      if (code == null) return StoreMessage.literal(name);
      final stored = json['arguments'];
      return StoreMessage(
        code,
        stored is List ? List<Object?>.of(stored) : const <Object?>[],
      );
    }
    return StoreMessage.literal('$json');
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code.slug,
    'arguments': arguments,
  };

  /// The text of a [StoreMessageCode.literalCopy] message, empty when the
  /// stored entry carried none.
  String get literalText => arguments.isEmpty ? '' : '${arguments.first}';

  @override
  bool operator ==(Object other) =>
      other is StoreMessage &&
      other.code == code &&
      _sameArguments(other.arguments);

  bool _sameArguments(List<Object?> other) {
    if (other.length != arguments.length) return false;
    for (var index = 0; index < arguments.length; index++) {
      if (other[index] != arguments[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(code, Object.hashAll(arguments));

  /// The code and its arguments, for a log or a failed test. Not copy: the
  /// interface's words live in `lib/l10n/`.
  @override
  String toString() => '${code.slug}(${arguments.join(', ')})';
}

/// The codes the store layer and the source layer hand to a page (#72).
///
/// Every value's `slug` is also the ARB key its copy lives under, so
/// `StoreMessageCode.backupNoGroupMember` and
/// `AppLocalizations.backupNoGroupMember` are one concept with one spelling.
enum StoreMessageCode {
  /// This product's own retired JSON stores, reported by `LegacyImport`.
  legacyOnlineReadingNotImported,
  legacyOnlineReadingRecordWithoutSourceUrl,
  legacyOnlineReadingLastReadPointer,
  legacyLocalBooksNotParsed,
  legacyLocalBooksWithoutRoot,
  legacyLocalBookBytesExcluded,
  legacyLocalFilesMissing,
  legacyMigrationStateNotParsed,
  legacyMigrationNetworkBookWithoutUrl,

  /// The counts an import carried, on one line: `书源 3 · 书籍 6 …`.
  legacyImportSummary,

  /// The retired hand-made JSON envelope (`LegadoBackupImport`).
  backupEnvelopeExcludedFamilies,
  backupEnvelopeNoSources,
  backupEnvelopeNoBooks,
  backupEnvelopeNoProgress,
  backupEnvelopeSourceWithoutUrlOrName,
  backupEnvelopeBookWithoutKey,

  /// A Legado full backup's loss report (`LegadoFullBackupImport`).
  backupExcludedCookies,
  backupExcludedCache,
  backupExcludedChapters,
  backupExcludedDownloads,
  backupExcludedLocalBytes,
  backupAndroidPreferences,
  backupAbsentMember,
  backupUnreadMembers,
  backupInvalidSources,
  backupInvalidGroups,
  backupInvalidBooks,
  backupConflictingSources,
  backupDuplicateBooks,
  backupSystemGroups,
  backupUnmatchedMasks,
  backupUnreadBooks,
  backupNonTextSources,
  backupDroppedCovers,
  backupDroppedEntries,
  backupProgressChapterNameDropped,
  backupNoSourceMember,
  backupNoGroupMember,

  /// A replace rule the reader had to leave out, reported on the reader page's
  /// notice surface (`ContentProcessing.onNotice`).
  replaceRuleUnusable,
  replaceRuleTimedOut,
  replaceRuleFailed,

  /// The line the shelf's controlled-source card shows while a run advances
  /// (`BookSourceRunState.message`).
  runSearching,
  runReading,
  runReadingToc,
  runJsonFirstChapterDone,
  runFailed,
  runControlledSearch,
  runControlledBookInfo,
  runControlledToc,
  runControlledContent,
  runControlledCompleted,

  /// A message that is its own copy, for a stored entry written before this
  /// seam existed ([StoreMessage.literal]).
  literalCopy;

  /// The code a stored slug names, or null when this build does not know it.
  static StoreMessageCode? bySlug(String slug) {
    for (final code in values) {
      if (code.slug == slug) return code;
    }
    return null;
  }

  /// The name a stored report holds for this code.
  String get slug => name;
}
