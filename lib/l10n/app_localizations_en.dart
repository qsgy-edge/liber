// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get shelfTitle => 'Bookshelf';

  @override
  String get navLocalLibrary => 'Local library';

  @override
  String get navMigration => 'Migration';

  @override
  String get actionPreciseSearch => 'Precise search';

  @override
  String get actionSourceTrial => 'Source trial';

  @override
  String get actionAutoChangeSource => 'Automatic source switch';

  @override
  String get readerScriptTitle => 'Chinese conversion';

  @override
  String get imageLoadFailed => 'Image failed to load';

  @override
  String get imageLoading => 'Loading the image…';

  @override
  String get imageEmptyAddress => 'The image address is empty';

  @override
  String get actionInterfaceLanguage => 'Interface language';

  @override
  String get shelfSubtitle =>
      'Windows-first MVP · shared book-source contract workbench';

  @override
  String get controlledSourceTitle => 'Wayfinder controlled source';

  @override
  String get controlledSourceDescription =>
      'The smallest path that exercises search, book information, table of contents and content.';

  @override
  String get notRunYet => 'Not run yet';

  @override
  String get runControlledSource => 'Run the controlled source';

  @override
  String get stageSearch => 'Search';

  @override
  String get stageBookInfo => 'Book information';

  @override
  String get stageTableOfContents => 'Table of contents';

  @override
  String get stageContent => 'Content';

  @override
  String get openingSpaceStore => 'Opening the space store…';

  @override
  String spaceStoreUnavailable(String error) {
    return 'The space store is unavailable: $error';
  }

  @override
  String legacyImportFailed(String error) {
    return 'Importing the old data failed: $error';
  }

  @override
  String get migratedBooksTitle => 'Migrated books';

  @override
  String needsRelinkOffset(int offset) {
    return 'Needs its local file relinked · offset: $offset';
  }

  @override
  String migratedProgressOffset(int offset) {
    return 'Migrated progress offset: $offset';
  }

  @override
  String get localBooksTitle => 'Local books';

  @override
  String progressOffset(int offset) {
    return 'Progress offset: $offset';
  }

  @override
  String get requestTraceTitle => 'Request trace';

  @override
  String get contractNotice =>
      'This stage runs the controlled fixture only. The fjs host-callback lifecycle and the isolation of untrusted book sources are still open gates; the Windows MVP is not five-platform compatibility.';

  @override
  String get noRootFolder => 'No folder authorized yet';

  @override
  String currentFolder(String path) {
    return 'Current folder: $path';
  }

  @override
  String currentFolderRelink(String path) {
    return 'Current folder: $path (unavailable; choose the root folder again)';
  }

  @override
  String get chooseRootFolder => 'Choose the root folder';

  @override
  String get goUp => 'Go up';

  @override
  String get scanRecursively => 'Scan this folder recursively';

  @override
  String get addToShelf => 'Add to the shelf explicitly';

  @override
  String get addEntryToShelf => 'Add to the shelf';

  @override
  String get folder => 'Folder';

  @override
  String get textFile => 'TXT/Markdown file';

  @override
  String get openFolder => 'Open the folder';

  @override
  String get scanEmpty => 'The scan found nothing';

  @override
  String rootSelected(String name) {
    return 'Root folder selected: $name';
  }

  @override
  String scanFinished(int count) {
    return 'Recursive scan done: found $count TXT/Markdown files';
  }

  @override
  String get noNewFiles => 'No new files were added to the shelf';

  @override
  String get fileAlreadyOnShelf => 'That file is already on the shelf';

  @override
  String fileAdded(String title) {
    return 'Added $title';
  }

  @override
  String shelfLocalBookCount(int count) {
    return 'The shelf holds $count local books';
  }

  @override
  String filesAdded(int count) {
    return 'Added $count books explicitly';
  }

  @override
  String get spaceStoreTitle => 'Space store';

  @override
  String get notCreatedYet => 'Not created yet';

  @override
  String get opening => 'Opening…';

  @override
  String importedNow(String at, String summary) {
    return 'The old data was imported this run ($at): $summary';
  }

  @override
  String get nothingToImport => 'There is no old data to import';

  @override
  String alreadyImported(String at, String summary) {
    return 'Imported at $at already: $summary; nothing was imported again this run';
  }

  @override
  String get migrationIntro =>
      'Pick a Legado backup ZIP (recommended) or JSON file: the import is previewed first, and the data that cannot be migrated is reported.';

  @override
  String get chooseLegadoBackup => 'Choose a Legado backup';

  @override
  String get importPreviewDone => 'Import preview ready';

  @override
  String get importedSourcesTitle => 'Imported book sources';

  @override
  String get sourceActions => 'Source actions';

  @override
  String get loginAction => 'Log in';

  @override
  String get editSourceUrlAction => 'Edit book source URL';

  @override
  String get deleteSource => 'Delete book source';

  @override
  String get urlMissing => 'No URL given';

  @override
  String get importPreviewTitle => 'Import preview';

  @override
  String previewSources(int count) {
    return 'Book sources: $count';
  }

  @override
  String previewBooks(int count) {
    return 'Shelf: $count';
  }

  @override
  String previewProgress(int count) {
    return 'Reading progress: $count';
  }

  @override
  String deleteSourceQuestion(String name, String ref) {
    return 'Delete book source “$name”? ($ref)\n\nIts cache, variables, written cookies and confirmed certificate exceptions are removed with it, and this cannot be undone. Books it added stay on the shelf, marked as a deleted source; importing a source with the same URL brings the reading back.';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get save => 'Save';

  @override
  String sourceDeleted(String name) {
    return 'Deleted book source: $name';
  }

  @override
  String deleteSourceFailed(String error) {
    return 'Deleting the book source failed: $error';
  }

  @override
  String editSourceUrlTitle(String name) {
    return 'Edit book source URL: $name';
  }

  @override
  String get sourceUrlEmpty => 'The book source URL cannot be empty';

  @override
  String sourceUrlTaken(String url) {
    return 'A book source with that URL already exists: $url';
  }

  @override
  String editSourceUrlFailed(String error) {
    return 'Editing the book source URL failed: $error';
  }

  @override
  String sourceUrlChanged(String from, String to) {
    return 'Changed the book source URL: $from → $to';
  }

  @override
  String sourceNotFound(String ref) {
    return 'Book source not found: $ref';
  }

  @override
  String sourceLoggedIn(String name) {
    return 'Logged in to book source: $name';
  }

  @override
  String get sourceTrialIntro =>
      'Search, pick a book, then read its table of contents and content. Today it supports the rules Shudugu and Jiuai use; login (loginUrl / loginUi / loginCheckJs) is supported, a remote shared script library is not.';

  @override
  String get chooseSourceAndKeyword =>
      'Choose a book source and enter a keyword.';

  @override
  String loadSourceFailed(String error) {
    return 'Loading failed: $error';
  }

  @override
  String get sourceJsonRequired =>
      'Choose a Legado single-source or source-array JSON';

  @override
  String sourcesLoaded(int count) {
    return 'Loaded $count book sources, for this trial only';
  }

  @override
  String readSourceFailed(String message) {
    return 'Reading failed: $message';
  }

  @override
  String get enterKeyword => 'Enter a keyword.';

  @override
  String get noOnlineReading => 'There is no online reading yet';

  @override
  String get lastReadSourceDeleted =>
      'The source of the last reading was deleted; import a source with the same URL to continue.';

  @override
  String resumeFailed(String error) {
    return 'Resuming failed: $error';
  }

  @override
  String get continueLastReading => 'Continue the last reading';

  @override
  String get shuduguLoaded => 'Shudugu loaded; search and then pick a book';

  @override
  String get useShuduguSource => 'Use the Shudugu source';

  @override
  String get chooseSourceJson => 'Choose a source JSON';

  @override
  String get searchKeyword => 'Search keyword';

  @override
  String get search => 'Search';

  @override
  String get followSystemLanguage => 'Follow the system language';

  @override
  String get scriptFollowInstallation => 'Follow the installation setting';

  @override
  String get scriptSimplified => 'Simplified';

  @override
  String get scriptTraditionalTaiwan => '繁體（台灣）';

  @override
  String get scriptTraditionalHongKong => '繁體（香港）';

  @override
  String get scriptTraditionalGeneric => 'Traditional (generic)';

  @override
  String get scriptNone => 'No conversion';

  @override
  String get describeSimplified => 'Simplified (mainland wording)';

  @override
  String get readerScriptDefault =>
      'The default follows the system language: zh-CN → Simplified (mainland wording), zh-TW → 繁體（台灣）, zh-HK → 繁體（香港）, any other language → no conversion.';

  @override
  String systemLocaleLine(String tag) {
    return 'System language: $tag';
  }

  @override
  String effectiveLine(String value) {
    return 'In effect: $value';
  }

  @override
  String get installationSettings => 'Installation settings';

  @override
  String get loading => 'Reading…';

  @override
  String bookOverride(String title) {
    return 'Override for this book: $title';
  }

  @override
  String readSettingsFailed(String error) {
    return 'Reading the setting failed: $error';
  }

  @override
  String saveSettingsFailed(String error) {
    return 'Saving the setting failed: $error';
  }

  @override
  String get interfaceLanguageIntro =>
      'The interface language changes the interface\'s own words only. The script of book content is the Chinese conversion setting; the two do not affect each other.';

  @override
  String get languageSimplified => 'Simplified Chinese';

  @override
  String get languageTraditionalTaiwan => 'Traditional Chinese (Taiwan)';

  @override
  String get languageTraditionalHongKong => 'Traditional Chinese (Hong Kong)';

  @override
  String get languageEnglish => 'English';

  @override
  String get interfaceLanguageFollowHint =>
      'Following the system: zh-CN → Simplified Chinese, zh-TW/zh-HK → Traditional Chinese, any other language → English.';

  @override
  String get onlineShelfTitle => 'Online shelf';

  @override
  String readOnlineShelfFailed(String error) {
    return 'Reading the online shelf failed: $error';
  }

  @override
  String get invalidBookUrl => 'Enter a valid http(s) book link';

  @override
  String get noSourceMatchesUrl => 'No book source matches that link';

  @override
  String get chooseSource => 'Choose a book source';

  @override
  String openBookUrlFailed(String error) {
    return 'Opening the link failed: $error';
  }

  @override
  String operationFailedShelfKept(String error) {
    return 'The operation failed; the shelf and the progress are kept: $error';
  }

  @override
  String get bookUrl => 'Book link';

  @override
  String get openBookUrl => 'Open the book link';

  @override
  String get retry => 'Retry';

  @override
  String get shelfFromSourceHint =>
      'Add a book to the shelf from a source\'s search results or its detail page.';

  @override
  String get sourceDeletedKept => 'Source deleted · entry and progress kept';

  @override
  String get notReadYet => 'Not read yet';

  @override
  String get continueLastChapter => 'Continue the last chapter';

  @override
  String get bookActions => 'Book actions';

  @override
  String get updateTableOfContents => 'Refresh the table of contents';

  @override
  String get switchSource => 'Switch source';

  @override
  String get removeFromShelf => 'Remove from the shelf (progress kept)';

  @override
  String replaceRulesFailed(String error) {
    return 'Reading the replace rules failed: $error';
  }

  @override
  String saveProgressFailed(String error) {
    return 'Saving the progress failed: $error';
  }

  @override
  String chapterLoadFailed(String error) {
    return 'Loading the chapter failed: $error';
  }

  @override
  String get closeTableOfContents => 'Close the table of contents';

  @override
  String get tableOfContentsAction => 'Table of contents';

  @override
  String tableOfContentsCount(int count) {
    return 'Table of contents · $count chapters';
  }

  @override
  String get previousChapter => 'Previous chapter';

  @override
  String get reloadChapter => 'Reload';

  @override
  String get nextChapter => 'Next chapter';

  @override
  String get preciseSearchTitle => 'Precise search';

  @override
  String switchSourceTitle(String title) {
    return 'Switch source: $title';
  }

  @override
  String currentSourceLine(String name, int offset) {
    return 'Current source: $name · progress offset $offset';
  }

  @override
  String get searchedSources => 'Book sources to search';

  @override
  String get bookName => 'Title';

  @override
  String get authorName => 'Author';

  @override
  String get mustMatchAuthor =>
      'Results must contain the author (the frozen changeSourceCheckAuthor)';

  @override
  String sourceErrorLine(String name, String failure) {
    return '$name failed: $failure';
  }

  @override
  String get noAuthor => '(no author)';

  @override
  String get exactMatch => 'Exact match';

  @override
  String get readingSources => 'Reading the book sources';

  @override
  String get noSourcesInSpace => 'The space has no book sources yet';

  @override
  String get chooseSourcesToSearch =>
      'Choose the book sources, then search by title';

  @override
  String loadSourcesFailed(String error) {
    return 'Reading the book sources failed: $error';
  }

  @override
  String get enterBookName => 'Enter a book title';

  @override
  String get chooseSourcesToSearchStatus => 'Choose the book sources to search';

  @override
  String searchingSources(int count) {
    return 'Searching $count book sources';
  }

  @override
  String searchingSource(Object index, Object name, Object total) {
    return 'Searching $name ($index/$total)';
  }

  @override
  String searchFailed(String error) {
    return 'The search failed: $error';
  }

  @override
  String noResults(String name, String author) {
    return 'Nothing found for <$name>$author';
  }

  @override
  String noResultsWithFailures(String name, String author, int count) {
    return 'Nothing found for <$name>$author ($count sources failed)';
  }

  @override
  String candidatesFound(int count, int exact) {
    return '$count candidates, $exact of them exact matches';
  }

  @override
  String readingSourceToc(String name) {
    return 'Reading $name\'s table of contents';
  }

  @override
  String switchedSource(String name, String title, String chapter, int offset) {
    return 'Switched to $name: $title · $chapter (offset $offset)';
  }

  @override
  String switchSourceFailed(String error) {
    return 'Switching the source failed: $error';
  }

  @override
  String get autoChangeSourceLabel =>
      'Switch source automatically when a book\'s source is deleted';

  @override
  String get autoChangeSourceHint =>
      'Opening a book whose book source has been deleted searches the enabled text sources for the same book name and author and moves the book onto the first one that answers with its content; a book with no suitable source stays on the shelf. On by default.';

  @override
  String get autoChangingSource => 'Switching source';

  @override
  String autoChangeSourceFailed(String error) {
    return 'Switching the source automatically failed\n$error';
  }

  @override
  String get noSuitableSource => 'No suitable book source';

  @override
  String get reading => 'Reading';

  @override
  String get chapterNotInToc =>
      'The chapter is no longer in the table of contents; the progress is kept, pick a chapter';

  @override
  String get searching => 'Searching';

  @override
  String booksFound(int count) {
    return '$count books found';
  }

  @override
  String get readingDetailsAndToc =>
      'Reading the details and the full table of contents';

  @override
  String addedToShelf(String title) {
    return 'Added to the shelf: $title';
  }

  @override
  String addToShelfFailed(String error) {
    return 'Adding to the shelf failed: $error';
  }

  @override
  String get searchResults => 'Search results';

  @override
  String get inShelf => 'On the shelf';

  @override
  String get backToSearchResults => 'Back to the search results';

  @override
  String loginSourceTitle(String name) {
    return 'Log in to book source: $name';
  }

  @override
  String get loginUiEmpty =>
      'This source\'s loginUi has no login form to show.';

  @override
  String readLoginInfoFailed(String message) {
    return 'Reading the login information failed: $message';
  }

  @override
  String get loginInfoUnavailable =>
      'The login information cannot be stored: the installation identity is not enough to derive the AES key (BaseSource.kt:180-192)';

  @override
  String loginError(String message) {
    return 'The login failed: $message';
  }

  @override
  String buttonExecuted(String name) {
    return 'Ran “$name”';
  }

  @override
  String buttonFailed(String name, String message) {
    return '“$name” failed: $message';
  }

  @override
  String get loginHeaderTitle => 'Login header';

  @override
  String get noLoginHeader => '(no login header stored)';

  @override
  String get copy => 'Copy';

  @override
  String get close => 'Close';

  @override
  String get loginHeaderCleared => 'The login header is cleared';

  @override
  String get loginHeaderAction => 'Login header';

  @override
  String get removeLoginHeader => 'Clear the login header';

  @override
  String get confirm => 'OK';

  @override
  String get certificateFailedTitle => 'Certificate validation failed';

  @override
  String certificateFailedBody(String name, String host, String reason) {
    return 'The TLS certificate for $host, reached for book source “$name”, failed validation: $reason.\n\nContinuing may let your connection be eavesdropped on or tampered with. Remember this exception for this book source only?';
  }

  @override
  String get unsafeContinue => 'Continue (unsafe)';

  @override
  String get positionSaved => 'The reading position is saved';

  @override
  String get savePosition => 'Save the position';

  @override
  String cannotRead(String error) {
    return 'Cannot read: $error';
  }

  @override
  String get readerRestoreRelocated =>
      'The file changed: the reading position was relocated by its anchor';

  @override
  String get readerRestoreSearched =>
      'The file changed: the reading position was found again in the file';

  @override
  String get readerRestoreLineIndex =>
      'The file was replaced: the reading position was restored by line number; please check';

  @override
  String get readerRestorePercentage =>
      'The file was replaced: the reading position was restored by percentage; please check';

  @override
  String get readerDeletedPosition =>
      'A replace rule rewrote this line: the reading position moved to the text at the change';

  @override
  String get previousPage => 'Previous page';

  @override
  String get nextPage => 'Next page';

  @override
  String get hatchImageTitle => 'The book source asks to show a captcha image';

  @override
  String get hatchPageTitle => 'The book source asks to show a page in the app';

  @override
  String hatchPageBodyImage(String name, String url, String wait) {
    return 'The book source “$name” asks to show the captcha image below:\n\n$url\n\n$wait\nThe page or image is chosen by that book source and may look like the site\'s login page. Continue only if you trust it.';
  }

  @override
  String hatchPageBodyPage(String name, String url, String wait) {
    return 'The book source “$name” asks to open the address below in the app:\n\n$url\n\n$wait\nThe page or image is chosen by that book source and may look like the site\'s login page. Continue only if you trust it.';
  }

  @override
  String get hatchWaits =>
      'The book source waits for you for up to five minutes.';

  @override
  String get hatchDoesNotWait =>
      'Once the page is shown, the book source does not wait.';

  @override
  String get hatchShowImage => 'Show the image';

  @override
  String get hatchOpenPage => 'Open the page';

  @override
  String get hatchCodeTitle => 'Captcha';

  @override
  String hatchSource(String name) {
    return 'Book source: $name';
  }

  @override
  String hatchImageFailed(String failure) {
    return 'Loading the image failed: $failure';
  }

  @override
  String get hatchAnswer => 'The code';

  @override
  String get hatchPageRoute => 'Book source page';

  @override
  String get done => 'Done';

  @override
  String importFileFailed(String error) {
    return 'Importing the file failed: $error';
  }

  @override
  String scriptConvertFailed(String error) {
    return 'Chinese conversion failed: $error';
  }

  @override
  String legacyOnlineReadingNotImported(String reason) {
    return 'online_reading.json was not imported: $reason (the original file is kept)';
  }

  @override
  String get legacyOnlineReadingRecordWithoutSourceUrl =>
      'An online-reading record has no bookSourceUrl and was skipped';

  @override
  String get legacyOnlineReadingLastReadPointer =>
      'The online-reading “last read” pointer has no equivalent field; the most recently saved progress answers instead';

  @override
  String get legacyLocalBooksNotParsed =>
      'local_books.json could not be parsed and was skipped (the original file is kept)';

  @override
  String get legacyLocalBooksWithoutRoot =>
      'local_books.json has no root folder and was not imported';

  @override
  String get legacyLocalBookBytesExcluded =>
      'Local file bytes are not imported; books whose file is missing are marked needsRelink';

  @override
  String legacyLocalFilesMissing(int count) {
    return '$count local files are no longer at their original path';
  }

  @override
  String get legacyMigrationStateNotParsed =>
      'migration_state.json could not be parsed and was skipped (the original file is kept)';

  @override
  String get legacyMigrationNetworkBookWithoutUrl =>
      'Network books in the migration record have no bookSourceUrl; only the title and the progress are kept';

  @override
  String legacyImportSummary(
    int sources,
    int books,
    int chapters,
    int progress,
    int localFiles,
  ) {
    return 'Book Sources $sources · Books $books · Chapters $chapters · Progress $progress · Local files $localFiles';
  }

  @override
  String get backupEnvelopeExcludedFamilies =>
      'Local file bytes, cookies, caches and downloaded content are never imported from a backup';

  @override
  String get backupEnvelopeNoSources => 'No Book Source data was found';

  @override
  String get backupEnvelopeNoBooks => 'No bookshelf data was found';

  @override
  String get backupEnvelopeNoProgress => 'No reading progress was found';

  @override
  String get backupEnvelopeSourceWithoutUrlOrName =>
      'A Book Source has neither a URL nor a name and was skipped';

  @override
  String get backupEnvelopeBookWithoutKey =>
      'A bookshelf record has no bookUrl/bookId/name and was skipped';

  @override
  String get backupExcludedCookies =>
      'Cookies: the backup carries no Cookie table, so the login state is not imported';

  @override
  String get backupExcludedCache =>
      'Caches: the backup carries no Cache table, so source caches are not imported';

  @override
  String get backupExcludedChapters =>
      'Chapters: the backup carries no BookChapter table, so the table of contents and the chapter variables are not imported';

  @override
  String get backupExcludedDownloads =>
      'Downloaded content: the backup carries no downloaded text; it has to be fetched again';

  @override
  String get backupExcludedLocalBytes =>
      'Local book bytes: the backup carries no book files; the books are marked for relinking';

  @override
  String backupAndroidPreferences(int count) {
    return 'Android settings: the $count preferences in config.xml belong to the Android app and are not imported';
  }

  @override
  String backupAbsentMember(String member) {
    return 'The backup has no $member: that data was empty';
  }

  @override
  String backupUnreadMembers(int count, String members) {
    return '$count more members of the backup were not imported: $members';
  }

  @override
  String backupInvalidSources(int count) {
    return '$count Book Sources lack a URL or a name and were skipped';
  }

  @override
  String backupInvalidGroups(int count) {
    return '$count groups have no name and were skipped';
  }

  @override
  String backupInvalidBooks(int count) {
    return '$count bookshelf records have no bookUrl and were skipped';
  }

  @override
  String backupConflictingSources(int count) {
    return '$count Book Sources already exist in the space with different content and were not replaced (replacing needs confirmation)';
  }

  @override
  String backupDuplicateBooks(int count) {
    return '$count bookshelf records repeat a bookUrl and were merged into one';
  }

  @override
  String backupSystemGroups(int count) {
    return '$count system groups (views such as all, local and audio) are not imported: they follow from the book type';
  }

  @override
  String backupUnmatchedMasks(int count) {
    return '$count books carry a group bit with no matching group in bookGroup.json';
  }

  @override
  String backupUnreadBooks(int count) {
    return '$count books have no reading progress in the backup (never opened), so no progress row was written';
  }

  @override
  String backupNonTextSources(int count) {
    return '$count non-text Book Sources were imported; v1 does not execute them (ADR 0012)';
  }

  @override
  String backupDroppedCovers(int count) {
    return '$count covers point at a local path and were not imported (local bytes are not migrated)';
  }

  @override
  String backupDroppedEntries(int count) {
    return '$count records are not JSON objects and were skipped';
  }

  @override
  String get backupProgressChapterNameDropped =>
      'A reading position\'s chapter name has no equivalent field; the position keeps only the chapter index and the character offset';

  @override
  String get backupNoSourceMember =>
      'The backup has no bookSource.json: no Book Sources were imported';

  @override
  String get backupNoGroupMember =>
      'The backup has no bookGroup.json: groups are not imported';

  @override
  String replaceRuleUnusable(String name, String reason) {
    return 'Replace rule “$name” is unusable: $reason';
  }

  @override
  String replaceRuleTimedOut(String name, int milliseconds) {
    return 'Replace rule “$name” timed out ($milliseconds ms) and was disabled';
  }

  @override
  String replaceRuleFailed(String name, String error) {
    return 'Replace rule “$name” failed: $error';
  }

  @override
  String get runSearching => 'Searching';

  @override
  String runReading(String name) {
    return 'Reading $name';
  }

  @override
  String get runReadingToc => 'Reading the table of contents';

  @override
  String get runJsonFirstChapterDone =>
      'The first chapter was read (JSON rule subset)';

  @override
  String runFailed(String stage, String error) {
    return '$stage: $error';
  }

  @override
  String get runControlledSearch => 'The search returned 1 book';

  @override
  String get runControlledBookInfo => 'Book information returned';

  @override
  String get runControlledToc => 'The table of contents returned 12 chapters';

  @override
  String get runControlledContent => 'Chapter text returned';

  @override
  String get runControlledCompleted =>
      'The Windows controlled Book Source chain completed; all 4 stages have a trace';

  @override
  String literalCopy(String text) {
    return '$text';
  }
}
