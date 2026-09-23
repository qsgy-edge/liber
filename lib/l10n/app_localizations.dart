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

  /// No description provided for @imageLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'图片加载失败'**
  String get imageLoadFailed;

  /// No description provided for @imageLoading.
  ///
  /// In zh, this message translates to:
  /// **'图片加载中…'**
  String get imageLoading;

  /// No description provided for @imageEmptyAddress.
  ///
  /// In zh, this message translates to:
  /// **'图片地址为空'**
  String get imageEmptyAddress;

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

  /// No description provided for @onlineShelfTitle.
  ///
  /// In zh, this message translates to:
  /// **'在线书架'**
  String get onlineShelfTitle;

  /// No description provided for @readOnlineShelfFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取在线书架失败：{error}'**
  String readOnlineShelfFailed(String error);

  /// No description provided for @invalidBookUrl.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的 http(s) 书籍链接'**
  String get invalidBookUrl;

  /// No description provided for @noSourceMatchesUrl.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配此链接的书源'**
  String get noSourceMatchesUrl;

  /// No description provided for @chooseSource.
  ///
  /// In zh, this message translates to:
  /// **'选择书源'**
  String get chooseSource;

  /// No description provided for @openBookUrlFailed.
  ///
  /// In zh, this message translates to:
  /// **'打开链接失败：{error}'**
  String openBookUrlFailed(String error);

  /// No description provided for @operationFailedShelfKept.
  ///
  /// In zh, this message translates to:
  /// **'操作失败，书架和进度仍保留：{error}'**
  String operationFailedShelfKept(String error);

  /// No description provided for @bookUrl.
  ///
  /// In zh, this message translates to:
  /// **'书籍链接'**
  String get bookUrl;

  /// No description provided for @openBookUrl.
  ///
  /// In zh, this message translates to:
  /// **'打开书籍链接'**
  String get openBookUrl;

  /// No description provided for @retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retry;

  /// No description provided for @shelfFromSourceHint.
  ///
  /// In zh, this message translates to:
  /// **'从书源搜索结果或详情页加入书架。'**
  String get shelfFromSourceHint;

  /// No description provided for @sourceDeletedKept.
  ///
  /// In zh, this message translates to:
  /// **'书源已删除 · 保留书目与进度'**
  String get sourceDeletedKept;

  /// No description provided for @notReadYet.
  ///
  /// In zh, this message translates to:
  /// **'尚未阅读'**
  String get notReadYet;

  /// No description provided for @continueLastChapter.
  ///
  /// In zh, this message translates to:
  /// **'继续上次章节'**
  String get continueLastChapter;

  /// No description provided for @bookActions.
  ///
  /// In zh, this message translates to:
  /// **'书籍操作'**
  String get bookActions;

  /// No description provided for @updateTableOfContents.
  ///
  /// In zh, this message translates to:
  /// **'更新目录'**
  String get updateTableOfContents;

  /// No description provided for @switchSource.
  ///
  /// In zh, this message translates to:
  /// **'换源'**
  String get switchSource;

  /// No description provided for @removeFromShelf.
  ///
  /// In zh, this message translates to:
  /// **'移出书架（保留进度）'**
  String get removeFromShelf;

  /// No description provided for @replaceRulesFailed.
  ///
  /// In zh, this message translates to:
  /// **'替换规则读取失败：{error}'**
  String replaceRulesFailed(String error);

  /// No description provided for @saveProgressFailed.
  ///
  /// In zh, this message translates to:
  /// **'进度保存失败：{error}'**
  String saveProgressFailed(String error);

  /// No description provided for @chapterLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'章节读取失败：{error}'**
  String chapterLoadFailed(String error);

  /// No description provided for @closeTableOfContents.
  ///
  /// In zh, this message translates to:
  /// **'关闭目录'**
  String get closeTableOfContents;

  /// No description provided for @tableOfContentsAction.
  ///
  /// In zh, this message translates to:
  /// **'目录'**
  String get tableOfContentsAction;

  /// No description provided for @tableOfContentsCount.
  ///
  /// In zh, this message translates to:
  /// **'目录 · {count} 章'**
  String tableOfContentsCount(int count);

  /// No description provided for @previousChapter.
  ///
  /// In zh, this message translates to:
  /// **'上一章'**
  String get previousChapter;

  /// No description provided for @reloadChapter.
  ///
  /// In zh, this message translates to:
  /// **'重新加载'**
  String get reloadChapter;

  /// No description provided for @nextChapter.
  ///
  /// In zh, this message translates to:
  /// **'下一章'**
  String get nextChapter;

  /// No description provided for @preciseSearchTitle.
  ///
  /// In zh, this message translates to:
  /// **'精确搜索'**
  String get preciseSearchTitle;

  /// No description provided for @switchSourceTitle.
  ///
  /// In zh, this message translates to:
  /// **'换源：{title}'**
  String switchSourceTitle(String title);

  /// No description provided for @currentSourceLine.
  ///
  /// In zh, this message translates to:
  /// **'当前书源：{name} · 进度 offset {offset}'**
  String currentSourceLine(String name, int offset);

  /// No description provided for @searchedSources.
  ///
  /// In zh, this message translates to:
  /// **'搜索的书源'**
  String get searchedSources;

  /// No description provided for @bookName.
  ///
  /// In zh, this message translates to:
  /// **'书名'**
  String get bookName;

  /// No description provided for @authorName.
  ///
  /// In zh, this message translates to:
  /// **'作者'**
  String get authorName;

  /// No description provided for @mustMatchAuthor.
  ///
  /// In zh, this message translates to:
  /// **'结果必须包含作者（冻结的 changeSourceCheckAuthor）'**
  String get mustMatchAuthor;

  /// No description provided for @sourceErrorLine.
  ///
  /// In zh, this message translates to:
  /// **'{name} 出错：{failure}'**
  String sourceErrorLine(String name, String failure);

  /// No description provided for @noAuthor.
  ///
  /// In zh, this message translates to:
  /// **'（无作者）'**
  String get noAuthor;

  /// No description provided for @exactMatch.
  ///
  /// In zh, this message translates to:
  /// **'精确匹配'**
  String get exactMatch;

  /// No description provided for @readingSources.
  ///
  /// In zh, this message translates to:
  /// **'正在读取书源'**
  String get readingSources;

  /// No description provided for @noSourcesInSpace.
  ///
  /// In zh, this message translates to:
  /// **'空间里还没有书源'**
  String get noSourcesInSpace;

  /// No description provided for @chooseSourcesToSearch.
  ///
  /// In zh, this message translates to:
  /// **'选择书源，输入书名后搜索'**
  String get chooseSourcesToSearch;

  /// No description provided for @loadSourcesFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取书源失败：{error}'**
  String loadSourcesFailed(String error);

  /// No description provided for @enterBookName.
  ///
  /// In zh, this message translates to:
  /// **'请输入书名'**
  String get enterBookName;

  /// No description provided for @chooseSourcesToSearchStatus.
  ///
  /// In zh, this message translates to:
  /// **'请选择要搜索的书源'**
  String get chooseSourcesToSearchStatus;

  /// No description provided for @searchingSources.
  ///
  /// In zh, this message translates to:
  /// **'正在搜索 {count} 个书源'**
  String searchingSources(int count);

  /// No description provided for @searchingSource.
  ///
  /// In zh, this message translates to:
  /// **'正在搜索 {name}（{index}/{total}）'**
  String searchingSource(Object index, Object name, Object total);

  /// No description provided for @searchFailed.
  ///
  /// In zh, this message translates to:
  /// **'搜索失败：{error}'**
  String searchFailed(String error);

  /// No description provided for @noResults.
  ///
  /// In zh, this message translates to:
  /// **'没有搜索到<{name}>{author}'**
  String noResults(String name, String author);

  /// No description provided for @noResultsWithFailures.
  ///
  /// In zh, this message translates to:
  /// **'没有搜索到<{name}>{author}（{count} 个书源出错）'**
  String noResultsWithFailures(String name, String author, int count);

  /// No description provided for @candidatesFound.
  ///
  /// In zh, this message translates to:
  /// **'候选 {count} 本，其中精确匹配 {exact} 本'**
  String candidatesFound(int count, int exact);

  /// No description provided for @readingSourceToc.
  ///
  /// In zh, this message translates to:
  /// **'正在读取 {name} 的目录'**
  String readingSourceToc(String name);

  /// No description provided for @switchedSource.
  ///
  /// In zh, this message translates to:
  /// **'已换源到 {name}：{title} · {chapter}（offset {offset}）'**
  String switchedSource(String name, String title, String chapter, int offset);

  /// No description provided for @switchSourceFailed.
  ///
  /// In zh, this message translates to:
  /// **'换源失败：{error}'**
  String switchSourceFailed(String error);

  /// No description provided for @reading.
  ///
  /// In zh, this message translates to:
  /// **'正在读取'**
  String get reading;

  /// No description provided for @chapterNotInToc.
  ///
  /// In zh, this message translates to:
  /// **'原章节已不在目录中，进度仍保留，请选择章节'**
  String get chapterNotInToc;

  /// No description provided for @searching.
  ///
  /// In zh, this message translates to:
  /// **'正在搜索'**
  String get searching;

  /// No description provided for @booksFound.
  ///
  /// In zh, this message translates to:
  /// **'找到 {count} 本书'**
  String booksFound(int count);

  /// No description provided for @readingDetailsAndToc.
  ///
  /// In zh, this message translates to:
  /// **'正在读取详情和完整目录'**
  String get readingDetailsAndToc;

  /// No description provided for @addedToShelf.
  ///
  /// In zh, this message translates to:
  /// **'已加入书架：{title}'**
  String addedToShelf(String title);

  /// No description provided for @addToShelfFailed.
  ///
  /// In zh, this message translates to:
  /// **'加入书架失败：{error}'**
  String addToShelfFailed(String error);

  /// No description provided for @searchResults.
  ///
  /// In zh, this message translates to:
  /// **'搜索结果'**
  String get searchResults;

  /// No description provided for @inShelf.
  ///
  /// In zh, this message translates to:
  /// **'已在书架'**
  String get inShelf;

  /// No description provided for @backToSearchResults.
  ///
  /// In zh, this message translates to:
  /// **'返回搜索结果'**
  String get backToSearchResults;

  /// No description provided for @loginSourceTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录书源：{name}'**
  String loginSourceTitle(String name);

  /// No description provided for @loginUiEmpty.
  ///
  /// In zh, this message translates to:
  /// **'该书源的 loginUi 没有可显示的登录界面。'**
  String get loginUiEmpty;

  /// No description provided for @readLoginInfoFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取登录信息失败：{message}'**
  String readLoginInfoFailed(String message);

  /// No description provided for @loginInfoUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'无法保存登录信息：安装标识不足以生成 AES 密钥（BaseSource.kt:180-192）'**
  String get loginInfoUnavailable;

  /// No description provided for @loginError.
  ///
  /// In zh, this message translates to:
  /// **'登录出错：{message}'**
  String loginError(String message);

  /// No description provided for @buttonExecuted.
  ///
  /// In zh, this message translates to:
  /// **'已执行“{name}”'**
  String buttonExecuted(String name);

  /// No description provided for @buttonFailed.
  ///
  /// In zh, this message translates to:
  /// **'“{name}”执行失败：{message}'**
  String buttonFailed(String name, String message);

  /// No description provided for @loginHeaderTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录头部信息'**
  String get loginHeaderTitle;

  /// No description provided for @noLoginHeader.
  ///
  /// In zh, this message translates to:
  /// **'（没有保存登录头部信息）'**
  String get noLoginHeader;

  /// No description provided for @copy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get copy;

  /// No description provided for @close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get close;

  /// No description provided for @loginHeaderCleared.
  ///
  /// In zh, this message translates to:
  /// **'已清除登录头部信息'**
  String get loginHeaderCleared;

  /// No description provided for @loginHeaderAction.
  ///
  /// In zh, this message translates to:
  /// **'登录头部'**
  String get loginHeaderAction;

  /// No description provided for @removeLoginHeader.
  ///
  /// In zh, this message translates to:
  /// **'清除登录头部'**
  String get removeLoginHeader;

  /// No description provided for @confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get confirm;

  /// No description provided for @certificateFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'证书校验失败'**
  String get certificateFailedTitle;

  /// No description provided for @certificateFailedBody.
  ///
  /// In zh, this message translates to:
  /// **'书源“{name}”访问 {host} 时，TLS 证书校验失败：{reason}。\n\n继续访问可能让你的连接被窃听或篡改。是否仅为此书源记住此次例外？'**
  String certificateFailedBody(String name, String host, String reason);

  /// No description provided for @unsafeContinue.
  ///
  /// In zh, this message translates to:
  /// **'继续（不安全）'**
  String get unsafeContinue;

  /// No description provided for @positionSaved.
  ///
  /// In zh, this message translates to:
  /// **'阅读位置已保存'**
  String get positionSaved;

  /// No description provided for @savePosition.
  ///
  /// In zh, this message translates to:
  /// **'保存位置'**
  String get savePosition;

  /// No description provided for @cannotRead.
  ///
  /// In zh, this message translates to:
  /// **'无法读取：{error}'**
  String cannotRead(String error);

  /// No description provided for @previousPage.
  ///
  /// In zh, this message translates to:
  /// **'上一页'**
  String get previousPage;

  /// No description provided for @nextPage.
  ///
  /// In zh, this message translates to:
  /// **'下一页'**
  String get nextPage;

  /// No description provided for @hatchImageTitle.
  ///
  /// In zh, this message translates to:
  /// **'书源请求显示验证码图片'**
  String get hatchImageTitle;

  /// No description provided for @hatchPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'书源请求在应用内显示页面'**
  String get hatchPageTitle;

  /// No description provided for @hatchPageBodyImage.
  ///
  /// In zh, this message translates to:
  /// **'书源“{name}”请求显示下面的验证码图片：\n\n{url}\n\n{wait}\n页面或图片由该书源指定，可能看起来像该网站的登录页。只有你信任该书源时才继续。'**
  String hatchPageBodyImage(String name, String url, String wait);

  /// No description provided for @hatchPageBodyPage.
  ///
  /// In zh, this message translates to:
  /// **'书源“{name}”请求在应用内打开下面的地址：\n\n{url}\n\n{wait}\n页面或图片由该书源指定，可能看起来像该网站的登录页。只有你信任该书源时才继续。'**
  String hatchPageBodyPage(String name, String url, String wait);

  /// No description provided for @hatchWaits.
  ///
  /// In zh, this message translates to:
  /// **'书源会一直等待你的操作，最长 5 分钟。'**
  String get hatchWaits;

  /// No description provided for @hatchDoesNotWait.
  ///
  /// In zh, this message translates to:
  /// **'页面显示后，书源不会等待。'**
  String get hatchDoesNotWait;

  /// No description provided for @hatchShowImage.
  ///
  /// In zh, this message translates to:
  /// **'显示图片'**
  String get hatchShowImage;

  /// No description provided for @hatchOpenPage.
  ///
  /// In zh, this message translates to:
  /// **'打开页面'**
  String get hatchOpenPage;

  /// No description provided for @hatchCodeTitle.
  ///
  /// In zh, this message translates to:
  /// **'验证码'**
  String get hatchCodeTitle;

  /// No description provided for @hatchSource.
  ///
  /// In zh, this message translates to:
  /// **'书源：{name}'**
  String hatchSource(String name);

  /// No description provided for @hatchImageFailed.
  ///
  /// In zh, this message translates to:
  /// **'图片加载失败：{failure}'**
  String hatchImageFailed(String failure);

  /// No description provided for @hatchAnswer.
  ///
  /// In zh, this message translates to:
  /// **'验证结果'**
  String get hatchAnswer;

  /// No description provided for @hatchPageRoute.
  ///
  /// In zh, this message translates to:
  /// **'书源页面'**
  String get hatchPageRoute;

  /// No description provided for @done.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get done;
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
