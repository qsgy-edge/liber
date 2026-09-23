import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
    Locale.fromSubtags(
      languageCode: 'zh',
      countryCode: 'HK',
      scriptCode: 'Hant',
    ),
    Locale.fromSubtags(
      languageCode: 'zh',
      countryCode: 'TW',
      scriptCode: 'Hant',
    ),
  ];

  /// No description provided for @shelfTitle.
  ///
  /// In zh, this message translates to:
  /// **'书架'**
  String get shelfTitle;

  /// No description provided for @navLocalLibrary.
  ///
  /// In zh, this message translates to:
  /// **'本地书库'**
  String get navLocalLibrary;

  /// No description provided for @navMigration.
  ///
  /// In zh, this message translates to:
  /// **'迁移'**
  String get navMigration;

  /// No description provided for @actionPreciseSearch.
  ///
  /// In zh, this message translates to:
  /// **'精确搜索'**
  String get actionPreciseSearch;

  /// No description provided for @actionSourceTrial.
  ///
  /// In zh, this message translates to:
  /// **'书源试读'**
  String get actionSourceTrial;

  /// No description provided for @readerScriptTitle.
  ///
  /// In zh, this message translates to:
  /// **'中文转换'**
  String get readerScriptTitle;

  /// No description provided for @actionInterfaceLanguage.
  ///
  /// In zh, this message translates to:
  /// **'界面语言'**
  String get actionInterfaceLanguage;

  /// No description provided for @shelfSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'Windows-first MVP · 共享书源契约验证台'**
  String get shelfSubtitle;

  /// No description provided for @controlledSourceTitle.
  ///
  /// In zh, this message translates to:
  /// **'Wayfinder 受控书源'**
  String get controlledSourceTitle;

  /// No description provided for @controlledSourceDescription.
  ///
  /// In zh, this message translates to:
  /// **'用于验证搜索、书籍信息、目录和正文的最小链路。'**
  String get controlledSourceDescription;

  /// No description provided for @notRunYet.
  ///
  /// In zh, this message translates to:
  /// **'尚未运行'**
  String get notRunYet;

  /// No description provided for @runControlledSource.
  ///
  /// In zh, this message translates to:
  /// **'运行受控书源'**
  String get runControlledSource;

  /// No description provided for @stageSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get stageSearch;

  /// No description provided for @stageBookInfo.
  ///
  /// In zh, this message translates to:
  /// **'书籍信息'**
  String get stageBookInfo;

  /// No description provided for @stageTableOfContents.
  ///
  /// In zh, this message translates to:
  /// **'目录'**
  String get stageTableOfContents;

  /// No description provided for @stageContent.
  ///
  /// In zh, this message translates to:
  /// **'正文'**
  String get stageContent;

  /// No description provided for @openingSpaceStore.
  ///
  /// In zh, this message translates to:
  /// **'正在打开空间存储…'**
  String get openingSpaceStore;

  /// No description provided for @spaceStoreUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'空间存储不可用：{error}'**
  String spaceStoreUnavailable(String error);

  /// No description provided for @legacyImportFailed.
  ///
  /// In zh, this message translates to:
  /// **'旧数据导入失败：{error}'**
  String legacyImportFailed(String error);

  /// No description provided for @migratedBooksTitle.
  ///
  /// In zh, this message translates to:
  /// **'已迁移书籍'**
  String get migratedBooksTitle;

  /// No description provided for @needsRelinkOffset.
  ///
  /// In zh, this message translates to:
  /// **'需要重新关联本地文件 · offset：{offset}'**
  String needsRelinkOffset(int offset);

  /// No description provided for @migratedProgressOffset.
  ///
  /// In zh, this message translates to:
  /// **'迁移进度 offset：{offset}'**
  String migratedProgressOffset(int offset);

  /// No description provided for @localBooksTitle.
  ///
  /// In zh, this message translates to:
  /// **'本地书'**
  String get localBooksTitle;

  /// No description provided for @progressOffset.
  ///
  /// In zh, this message translates to:
  /// **'进度 offset：{offset}'**
  String progressOffset(int offset);

  /// No description provided for @requestTraceTitle.
  ///
  /// In zh, this message translates to:
  /// **'请求 trace'**
  String get requestTraceTitle;

  /// No description provided for @contractNotice.
  ///
  /// In zh, this message translates to:
  /// **'当前阶段只运行受控 fixture。fjs 的 host callback 生命周期和不可信书源隔离仍是明确门禁；Windows MVP 不代表五平台兼容性已完成。'**
  String get contractNotice;

  /// No description provided for @noRootFolder.
  ///
  /// In zh, this message translates to:
  /// **'尚未授权目录'**
  String get noRootFolder;

  /// No description provided for @currentFolder.
  ///
  /// In zh, this message translates to:
  /// **'当前位置：{path}'**
  String currentFolder(String path);

  /// No description provided for @currentFolderRelink.
  ///
  /// In zh, this message translates to:
  /// **'当前位置：{path}（目录不可用，请重新选择根目录）'**
  String currentFolderRelink(String path);

  /// No description provided for @chooseRootFolder.
  ///
  /// In zh, this message translates to:
  /// **'选择根目录'**
  String get chooseRootFolder;

  /// No description provided for @goUp.
  ///
  /// In zh, this message translates to:
  /// **'返回上级'**
  String get goUp;

  /// No description provided for @scanRecursively.
  ///
  /// In zh, this message translates to:
  /// **'递归扫描当前目录'**
  String get scanRecursively;

  /// No description provided for @addToShelf.
  ///
  /// In zh, this message translates to:
  /// **'显式加入书架'**
  String get addToShelf;

  /// No description provided for @addEntryToShelf.
  ///
  /// In zh, this message translates to:
  /// **'加入书架'**
  String get addEntryToShelf;

  /// No description provided for @folder.
  ///
  /// In zh, this message translates to:
  /// **'文件夹'**
  String get folder;

  /// No description provided for @textFile.
  ///
  /// In zh, this message translates to:
  /// **'TXT/Markdown 文件'**
  String get textFile;

  /// No description provided for @openFolder.
  ///
  /// In zh, this message translates to:
  /// **'打开文件夹'**
  String get openFolder;

  /// No description provided for @scanEmpty.
  ///
  /// In zh, this message translates to:
  /// **'扫描结果为空'**
  String get scanEmpty;

  /// No description provided for @rootSelected.
  ///
  /// In zh, this message translates to:
  /// **'已选择根目录：{name}'**
  String rootSelected(String name);

  /// No description provided for @scanFinished.
  ///
  /// In zh, this message translates to:
  /// **'递归扫描完成：发现 {count} 个 TXT/Markdown 文件'**
  String scanFinished(int count);

  /// No description provided for @noNewFiles.
  ///
  /// In zh, this message translates to:
  /// **'没有新的文件加入书架'**
  String get noNewFiles;

  /// No description provided for @fileAlreadyOnShelf.
  ///
  /// In zh, this message translates to:
  /// **'该文件已经在书架中'**
  String get fileAlreadyOnShelf;

  /// No description provided for @fileAdded.
  ///
  /// In zh, this message translates to:
  /// **'已加入 {title}'**
  String fileAdded(String title);

  /// No description provided for @shelfLocalBookCount.
  ///
  /// In zh, this message translates to:
  /// **'书架已加入 {count} 本本地书'**
  String shelfLocalBookCount(int count);

  /// No description provided for @filesAdded.
  ///
  /// In zh, this message translates to:
  /// **'已显式加入 {count} 本书'**
  String filesAdded(int count);

  /// No description provided for @spaceStoreTitle.
  ///
  /// In zh, this message translates to:
  /// **'空间存储'**
  String get spaceStoreTitle;

  /// No description provided for @notCreatedYet.
  ///
  /// In zh, this message translates to:
  /// **'尚未创建'**
  String get notCreatedYet;

  /// No description provided for @opening.
  ///
  /// In zh, this message translates to:
  /// **'正在打开…'**
  String get opening;

  /// No description provided for @importedNow.
  ///
  /// In zh, this message translates to:
  /// **'本次导入旧数据（{at}）：{summary}'**
  String importedNow(String at, String summary);

  /// No description provided for @nothingToImport.
  ///
  /// In zh, this message translates to:
  /// **'没有可导入的旧数据'**
  String get nothingToImport;

  /// No description provided for @alreadyImported.
  ///
  /// In zh, this message translates to:
  /// **'已在 {at} 导入过：{summary}，本次未重复导入'**
  String alreadyImported(String at, String summary);

  /// No description provided for @migrationIntro.
  ///
  /// In zh, this message translates to:
  /// **'选择 Legado 的备份 ZIP（推荐）或 JSON 文件，先做导入预览并报告无法迁移的数据。'**
  String get migrationIntro;

  /// No description provided for @chooseLegadoBackup.
  ///
  /// In zh, this message translates to:
  /// **'选择 Legado 备份'**
  String get chooseLegadoBackup;

  /// No description provided for @importPreviewDone.
  ///
  /// In zh, this message translates to:
  /// **'导入预览完成'**
  String get importPreviewDone;

  /// No description provided for @importedSourcesTitle.
  ///
  /// In zh, this message translates to:
  /// **'已导入书源'**
  String get importedSourcesTitle;

  /// No description provided for @sourceActions.
  ///
  /// In zh, this message translates to:
  /// **'书源操作'**
  String get sourceActions;

  /// No description provided for @loginAction.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get loginAction;

  /// No description provided for @editSourceUrlAction.
  ///
  /// In zh, this message translates to:
  /// **'修改书源 URL'**
  String get editSourceUrlAction;

  /// No description provided for @deleteSource.
  ///
  /// In zh, this message translates to:
  /// **'删除书源'**
  String get deleteSource;

  /// No description provided for @urlMissing.
  ///
  /// In zh, this message translates to:
  /// **'未提供 URL'**
  String get urlMissing;

  /// No description provided for @importPreviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入预览'**
  String get importPreviewTitle;

  /// No description provided for @previewSources.
  ///
  /// In zh, this message translates to:
  /// **'Book Sources：{count}'**
  String previewSources(int count);

  /// No description provided for @previewBooks.
  ///
  /// In zh, this message translates to:
  /// **'书架：{count}'**
  String previewBooks(int count);

  /// No description provided for @previewProgress.
  ///
  /// In zh, this message translates to:
  /// **'阅读进度：{count}'**
  String previewProgress(int count);

  /// No description provided for @deleteSourceQuestion.
  ///
  /// In zh, this message translates to:
  /// **'删除书源“{name}”？（{ref}）\n\n它的缓存、变量、写入的 Cookie 和已确认的证书例外会一起清理，不能撤销。书架上由它加入的书会保留（标记为书源已删除），重新导入同一 URL 的书源即可继续阅读。'**
  String deleteSourceQuestion(String name, String ref);

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @sourceDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除书源：{name}'**
  String sourceDeleted(String name);

  /// No description provided for @deleteSourceFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除书源失败：{error}'**
  String deleteSourceFailed(String error);

  /// No description provided for @editSourceUrlTitle.
  ///
  /// In zh, this message translates to:
  /// **'修改书源 URL：{name}'**
  String editSourceUrlTitle(String name);

  /// No description provided for @sourceUrlEmpty.
  ///
  /// In zh, this message translates to:
  /// **'书源 URL 不能为空'**
  String get sourceUrlEmpty;

  /// No description provided for @sourceUrlTaken.
  ///
  /// In zh, this message translates to:
  /// **'已存在 URL 相同的书源：{url}'**
  String sourceUrlTaken(String url);

  /// No description provided for @editSourceUrlFailed.
  ///
  /// In zh, this message translates to:
  /// **'修改书源 URL 失败：{error}'**
  String editSourceUrlFailed(String error);

  /// No description provided for @sourceUrlChanged.
  ///
  /// In zh, this message translates to:
  /// **'已修改书源 URL：{from} → {to}'**
  String sourceUrlChanged(String from, String to);

  /// No description provided for @sourceNotFound.
  ///
  /// In zh, this message translates to:
  /// **'找不到书源：{ref}'**
  String sourceNotFound(String ref);

  /// No description provided for @sourceLoggedIn.
  ///
  /// In zh, this message translates to:
  /// **'已登录书源：{name}'**
  String sourceLoggedIn(String name);

  /// No description provided for @sourceTrialIntro.
  ///
  /// In zh, this message translates to:
  /// **'搜索后选书，再查看目录和正文。当前支持速读谷及就爱文学所用的部分规则；登录（loginUrl / loginUi / loginCheckJs）已支持，远程共享脚本库尚未支持。'**
  String get sourceTrialIntro;

  /// No description provided for @chooseSourceAndKeyword.
  ///
  /// In zh, this message translates to:
  /// **'选择书源并输入关键词。'**
  String get chooseSourceAndKeyword;

  /// No description provided for @loadSourceFailed.
  ///
  /// In zh, this message translates to:
  /// **'载入失败：{error}'**
  String loadSourceFailed(String error);

  /// No description provided for @sourceJsonRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择 Legado 单个书源或书源数组 JSON'**
  String get sourceJsonRequired;

  /// No description provided for @sourcesLoaded.
  ///
  /// In zh, this message translates to:
  /// **'已载入 {count} 个书源，仅用于本次试读'**
  String sourcesLoaded(int count);

  /// No description provided for @readSourceFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取失败：{message}'**
  String readSourceFailed(String message);

  /// No description provided for @enterKeyword.
  ///
  /// In zh, this message translates to:
  /// **'请输入关键词。'**
  String get enterKeyword;

  /// No description provided for @noOnlineReading.
  ///
  /// In zh, this message translates to:
  /// **'尚无在线阅读记录'**
  String get noOnlineReading;

  /// No description provided for @lastReadSourceDeleted.
  ///
  /// In zh, this message translates to:
  /// **'上次阅读的书源已删除，重新导入同一 URL 的书源后可以继续。'**
  String get lastReadSourceDeleted;

  /// No description provided for @resumeFailed.
  ///
  /// In zh, this message translates to:
  /// **'恢复失败：{error}'**
  String resumeFailed(String error);

  /// No description provided for @continueLastReading.
  ///
  /// In zh, this message translates to:
  /// **'继续上次阅读'**
  String get continueLastReading;

  /// No description provided for @shuduguLoaded.
  ///
  /// In zh, this message translates to:
  /// **'已载入速读谷，点击搜索后选择书籍'**
  String get shuduguLoaded;

  /// No description provided for @useShuduguSource.
  ///
  /// In zh, this message translates to:
  /// **'使用速读谷书源'**
  String get useShuduguSource;

  /// No description provided for @chooseSourceJson.
  ///
  /// In zh, this message translates to:
  /// **'选择书源 JSON'**
  String get chooseSourceJson;

  /// No description provided for @searchKeyword.
  ///
  /// In zh, this message translates to:
  /// **'搜索关键词'**
  String get searchKeyword;

  /// No description provided for @search.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get search;

  /// No description provided for @followSystemLanguage.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统语言'**
  String get followSystemLanguage;

  /// No description provided for @scriptFollowInstallation.
  ///
  /// In zh, this message translates to:
  /// **'跟随全局设置'**
  String get scriptFollowInstallation;

  /// No description provided for @scriptSimplified.
  ///
  /// In zh, this message translates to:
  /// **'简体'**
  String get scriptSimplified;

  /// No description provided for @scriptTraditionalTaiwan.
  ///
  /// In zh, this message translates to:
  /// **'繁體（台灣）'**
  String get scriptTraditionalTaiwan;

  /// No description provided for @scriptTraditionalHongKong.
  ///
  /// In zh, this message translates to:
  /// **'繁體（香港）'**
  String get scriptTraditionalHongKong;

  /// No description provided for @scriptTraditionalGeneric.
  ///
  /// In zh, this message translates to:
  /// **'繁體（通用）'**
  String get scriptTraditionalGeneric;

  /// No description provided for @scriptNone.
  ///
  /// In zh, this message translates to:
  /// **'不转换'**
  String get scriptNone;

  /// No description provided for @describeSimplified.
  ///
  /// In zh, this message translates to:
  /// **'简体（大陆用词）'**
  String get describeSimplified;

  /// No description provided for @readerScriptDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认跟随系统语言：zh-CN → 简体（大陆用词），zh-TW → 繁體（台灣），zh-HK → 繁體（香港），其他语言 → 不转换。'**
  String get readerScriptDefault;

  /// No description provided for @systemLocaleLine.
  ///
  /// In zh, this message translates to:
  /// **'当前系统语言：{tag}'**
  String systemLocaleLine(String tag);

  /// No description provided for @effectiveLine.
  ///
  /// In zh, this message translates to:
  /// **'当前生效：{value}'**
  String effectiveLine(String value);

  /// No description provided for @installationSettings.
  ///
  /// In zh, this message translates to:
  /// **'安装设置'**
  String get installationSettings;

  /// No description provided for @loading.
  ///
  /// In zh, this message translates to:
  /// **'正在读取…'**
  String get loading;

  /// No description provided for @bookOverride.
  ///
  /// In zh, this message translates to:
  /// **'本书覆盖：{title}'**
  String bookOverride(String title);

  /// No description provided for @readSettingsFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取设置失败：{error}'**
  String readSettingsFailed(String error);

  /// No description provided for @saveSettingsFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存设置失败：{error}'**
  String saveSettingsFailed(String error);

  /// No description provided for @interfaceLanguageIntro.
  ///
  /// In zh, this message translates to:
  /// **'界面语言只换界面自己的文字。书籍内容的字形由“中文转换”决定，两者互不影响。'**
  String get interfaceLanguageIntro;

  /// No description provided for @languageSimplified.
  ///
  /// In zh, this message translates to:
  /// **'简体中文'**
  String get languageSimplified;

  /// No description provided for @languageTraditionalTaiwan.
  ///
  /// In zh, this message translates to:
  /// **'繁體中文（台灣）'**
  String get languageTraditionalTaiwan;

  /// No description provided for @languageTraditionalHongKong.
  ///
  /// In zh, this message translates to:
  /// **'繁體中文（香港）'**
  String get languageTraditionalHongKong;

  /// No description provided for @languageEnglish.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @interfaceLanguageFollowHint.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统：zh-CN → 简体中文，zh-TW/zh-HK → 繁體中文，其他语言 → English。'**
  String get interfaceLanguageFollowHint;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+script+country codes are specified.
  switch (locale.toString()) {
    case 'zh_Hant_HK':
      return AppLocalizationsZhHantHk();
    case 'zh_Hant_TW':
      return AppLocalizationsZhHantTw();
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
