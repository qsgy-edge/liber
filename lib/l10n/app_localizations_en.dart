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
  String get readerScriptTitle => 'Chinese conversion';

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
}
