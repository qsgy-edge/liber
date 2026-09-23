// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get shelfTitle => '书架';

  @override
  String get navLocalLibrary => '本地书库';

  @override
  String get navMigration => '迁移';

  @override
  String get actionPreciseSearch => '精确搜索';

  @override
  String get actionSourceTrial => '书源试读';

  @override
  String get readerScriptTitle => '中文转换';

  @override
  String get imageLoadFailed => '图片加载失败';

  @override
  String get imageLoading => '图片加载中…';

  @override
  String get imageEmptyAddress => '图片地址为空';

  @override
  String get actionInterfaceLanguage => '界面语言';

  @override
  String get shelfSubtitle => 'Windows-first MVP · 共享书源契约验证台';

  @override
  String get controlledSourceTitle => 'Wayfinder 受控书源';

  @override
  String get controlledSourceDescription => '用于验证搜索、书籍信息、目录和正文的最小链路。';

  @override
  String get notRunYet => '尚未运行';

  @override
  String get runControlledSource => '运行受控书源';

  @override
  String get stageSearch => '搜索';

  @override
  String get stageBookInfo => '书籍信息';

  @override
  String get stageTableOfContents => '目录';

  @override
  String get stageContent => '正文';

  @override
  String get openingSpaceStore => '正在打开空间存储…';

  @override
  String spaceStoreUnavailable(String error) {
    return '空间存储不可用：$error';
  }

  @override
  String legacyImportFailed(String error) {
    return '旧数据导入失败：$error';
  }

  @override
  String get migratedBooksTitle => '已迁移书籍';

  @override
  String needsRelinkOffset(int offset) {
    return '需要重新关联本地文件 · offset：$offset';
  }

  @override
  String migratedProgressOffset(int offset) {
    return '迁移进度 offset：$offset';
  }

  @override
  String get localBooksTitle => '本地书';

  @override
  String progressOffset(int offset) {
    return '进度 offset：$offset';
  }

  @override
  String get requestTraceTitle => '请求 trace';

  @override
  String get contractNotice =>
      '当前阶段只运行受控 fixture。fjs 的 host callback 生命周期和不可信书源隔离仍是明确门禁；Windows MVP 不代表五平台兼容性已完成。';

  @override
  String get noRootFolder => '尚未授权目录';

  @override
  String currentFolder(String path) {
    return '当前位置：$path';
  }

  @override
  String currentFolderRelink(String path) {
    return '当前位置：$path（目录不可用，请重新选择根目录）';
  }

  @override
  String get chooseRootFolder => '选择根目录';

  @override
  String get goUp => '返回上级';

  @override
  String get scanRecursively => '递归扫描当前目录';

  @override
  String get addToShelf => '显式加入书架';

  @override
  String get addEntryToShelf => '加入书架';

  @override
  String get folder => '文件夹';

  @override
  String get textFile => 'TXT/Markdown 文件';

  @override
  String get openFolder => '打开文件夹';

  @override
  String get scanEmpty => '扫描结果为空';

  @override
  String rootSelected(String name) {
    return '已选择根目录：$name';
  }

  @override
  String scanFinished(int count) {
    return '递归扫描完成：发现 $count 个 TXT/Markdown 文件';
  }

  @override
  String get noNewFiles => '没有新的文件加入书架';

  @override
  String get fileAlreadyOnShelf => '该文件已经在书架中';

  @override
  String fileAdded(String title) {
    return '已加入 $title';
  }

  @override
  String shelfLocalBookCount(int count) {
    return '书架已加入 $count 本本地书';
  }

  @override
  String filesAdded(int count) {
    return '已显式加入 $count 本书';
  }

  @override
  String get spaceStoreTitle => '空间存储';

  @override
  String get notCreatedYet => '尚未创建';

  @override
  String get opening => '正在打开…';

  @override
  String importedNow(String at, String summary) {
    return '本次导入旧数据（$at）：$summary';
  }

  @override
  String get nothingToImport => '没有可导入的旧数据';

  @override
  String alreadyImported(String at, String summary) {
    return '已在 $at 导入过：$summary，本次未重复导入';
  }

  @override
  String get migrationIntro =>
      '选择 Legado 的备份 ZIP（推荐）或 JSON 文件，先做导入预览并报告无法迁移的数据。';

  @override
  String get chooseLegadoBackup => '选择 Legado 备份';

  @override
  String get importPreviewDone => '导入预览完成';

  @override
  String get importedSourcesTitle => '已导入书源';

  @override
  String get sourceActions => '书源操作';

  @override
  String get loginAction => '登录';

  @override
  String get editSourceUrlAction => '修改书源 URL';

  @override
  String get deleteSource => '删除书源';

  @override
  String get urlMissing => '未提供 URL';

  @override
  String get importPreviewTitle => '导入预览';

  @override
  String previewSources(int count) {
    return 'Book Sources：$count';
  }

  @override
  String previewBooks(int count) {
    return '书架：$count';
  }

  @override
  String previewProgress(int count) {
    return '阅读进度：$count';
  }

  @override
  String deleteSourceQuestion(String name, String ref) {
    return '删除书源“$name”？（$ref）\n\n它的缓存、变量、写入的 Cookie 和已确认的证书例外会一起清理，不能撤销。书架上由它加入的书会保留（标记为书源已删除），重新导入同一 URL 的书源即可继续阅读。';
  }

  @override
  String get cancel => '取消';

  @override
  String get delete => '删除';

  @override
  String get save => '保存';

  @override
  String sourceDeleted(String name) {
    return '已删除书源：$name';
  }

  @override
  String deleteSourceFailed(String error) {
    return '删除书源失败：$error';
  }

  @override
  String editSourceUrlTitle(String name) {
    return '修改书源 URL：$name';
  }

  @override
  String get sourceUrlEmpty => '书源 URL 不能为空';

  @override
  String sourceUrlTaken(String url) {
    return '已存在 URL 相同的书源：$url';
  }

  @override
  String editSourceUrlFailed(String error) {
    return '修改书源 URL 失败：$error';
  }

  @override
  String sourceUrlChanged(String from, String to) {
    return '已修改书源 URL：$from → $to';
  }

  @override
  String sourceNotFound(String ref) {
    return '找不到书源：$ref';
  }

  @override
  String sourceLoggedIn(String name) {
    return '已登录书源：$name';
  }

  @override
  String get sourceTrialIntro =>
      '搜索后选书，再查看目录和正文。当前支持速读谷及就爱文学所用的部分规则；登录（loginUrl / loginUi / loginCheckJs）已支持，远程共享脚本库尚未支持。';

  @override
  String get chooseSourceAndKeyword => '选择书源并输入关键词。';

  @override
  String loadSourceFailed(String error) {
    return '载入失败：$error';
  }

  @override
  String get sourceJsonRequired => '请选择 Legado 单个书源或书源数组 JSON';

  @override
  String sourcesLoaded(int count) {
    return '已载入 $count 个书源，仅用于本次试读';
  }

  @override
  String readSourceFailed(String message) {
    return '读取失败：$message';
  }

  @override
  String get enterKeyword => '请输入关键词。';

  @override
  String get noOnlineReading => '尚无在线阅读记录';

  @override
  String get lastReadSourceDeleted => '上次阅读的书源已删除，重新导入同一 URL 的书源后可以继续。';

  @override
  String resumeFailed(String error) {
    return '恢复失败：$error';
  }

  @override
  String get continueLastReading => '继续上次阅读';

  @override
  String get shuduguLoaded => '已载入速读谷，点击搜索后选择书籍';

  @override
  String get useShuduguSource => '使用速读谷书源';

  @override
  String get chooseSourceJson => '选择书源 JSON';

  @override
  String get searchKeyword => '搜索关键词';

  @override
  String get search => '搜索';

  @override
  String get followSystemLanguage => '跟随系统语言';

  @override
  String get scriptFollowInstallation => '跟随全局设置';

  @override
  String get scriptSimplified => '简体';

  @override
  String get scriptTraditionalTaiwan => '繁體（台灣）';

  @override
  String get scriptTraditionalHongKong => '繁體（香港）';

  @override
  String get scriptTraditionalGeneric => '繁體（通用）';

  @override
  String get scriptNone => '不转换';

  @override
  String get describeSimplified => '简体（大陆用词）';

  @override
  String get readerScriptDefault =>
      '默认跟随系统语言：zh-CN → 简体（大陆用词），zh-TW → 繁體（台灣），zh-HK → 繁體（香港），其他语言 → 不转换。';

  @override
  String systemLocaleLine(String tag) {
    return '当前系统语言：$tag';
  }

  @override
  String effectiveLine(String value) {
    return '当前生效：$value';
  }

  @override
  String get installationSettings => '安装设置';

  @override
  String get loading => '正在读取…';

  @override
  String bookOverride(String title) {
    return '本书覆盖：$title';
  }

  @override
  String readSettingsFailed(String error) {
    return '读取设置失败：$error';
  }

  @override
  String saveSettingsFailed(String error) {
    return '保存设置失败：$error';
  }

  @override
  String get interfaceLanguageIntro => '界面语言只换界面自己的文字。书籍内容的字形由“中文转换”决定，两者互不影响。';

  @override
  String get languageSimplified => '简体中文';

  @override
  String get languageTraditionalTaiwan => '繁體中文（台灣）';

  @override
  String get languageTraditionalHongKong => '繁體中文（香港）';

  @override
  String get languageEnglish => 'English';

  @override
  String get interfaceLanguageFollowHint =>
      '跟随系统：zh-CN → 简体中文，zh-TW/zh-HK → 繁體中文，其他语言 → English。';

  @override
  String get onlineShelfTitle => '在线书架';

  @override
  String readOnlineShelfFailed(String error) {
    return '读取在线书架失败：$error';
  }

  @override
  String get invalidBookUrl => '请输入有效的 http(s) 书籍链接';

  @override
  String get noSourceMatchesUrl => '没有匹配此链接的书源';

  @override
  String get chooseSource => '选择书源';

  @override
  String openBookUrlFailed(String error) {
    return '打开链接失败：$error';
  }

  @override
  String operationFailedShelfKept(String error) {
    return '操作失败，书架和进度仍保留：$error';
  }

  @override
  String get bookUrl => '书籍链接';

  @override
  String get openBookUrl => '打开书籍链接';

  @override
  String get retry => '重试';

  @override
  String get shelfFromSourceHint => '从书源搜索结果或详情页加入书架。';

  @override
  String get sourceDeletedKept => '书源已删除 · 保留书目与进度';

  @override
  String get notReadYet => '尚未阅读';

  @override
  String get continueLastChapter => '继续上次章节';

  @override
  String get bookActions => '书籍操作';

  @override
  String get updateTableOfContents => '更新目录';

  @override
  String get switchSource => '换源';

  @override
  String get removeFromShelf => '移出书架（保留进度）';

  @override
  String replaceRulesFailed(String error) {
    return '替换规则读取失败：$error';
  }

  @override
  String saveProgressFailed(String error) {
    return '进度保存失败：$error';
  }

  @override
  String chapterLoadFailed(String error) {
    return '章节读取失败：$error';
  }

  @override
  String get closeTableOfContents => '关闭目录';

  @override
  String get tableOfContentsAction => '目录';

  @override
  String tableOfContentsCount(int count) {
    return '目录 · $count 章';
  }

  @override
  String get previousChapter => '上一章';

  @override
  String get reloadChapter => '重新加载';

  @override
  String get nextChapter => '下一章';

  @override
  String get preciseSearchTitle => '精确搜索';

  @override
  String switchSourceTitle(String title) {
    return '换源：$title';
  }

  @override
  String currentSourceLine(String name, int offset) {
    return '当前书源：$name · 进度 offset $offset';
  }

  @override
  String get searchedSources => '搜索的书源';

  @override
  String get bookName => '书名';

  @override
  String get authorName => '作者';

  @override
  String get mustMatchAuthor => '结果必须包含作者（冻结的 changeSourceCheckAuthor）';

  @override
  String sourceErrorLine(String name, String failure) {
    return '$name 出错：$failure';
  }

  @override
  String get noAuthor => '（无作者）';

  @override
  String get exactMatch => '精确匹配';

  @override
  String get readingSources => '正在读取书源';

  @override
  String get noSourcesInSpace => '空间里还没有书源';

  @override
  String get chooseSourcesToSearch => '选择书源，输入书名后搜索';

  @override
  String loadSourcesFailed(String error) {
    return '读取书源失败：$error';
  }

  @override
  String get enterBookName => '请输入书名';

  @override
  String get chooseSourcesToSearchStatus => '请选择要搜索的书源';

  @override
  String searchingSources(int count) {
    return '正在搜索 $count 个书源';
  }

  @override
  String searchingSource(Object index, Object name, Object total) {
    return '正在搜索 $name（$index/$total）';
  }

  @override
  String searchFailed(String error) {
    return '搜索失败：$error';
  }

  @override
  String noResults(String name, String author) {
    return '没有搜索到<$name>$author';
  }

  @override
  String noResultsWithFailures(String name, String author, int count) {
    return '没有搜索到<$name>$author（$count 个书源出错）';
  }

  @override
  String candidatesFound(int count, int exact) {
    return '候选 $count 本，其中精确匹配 $exact 本';
  }

  @override
  String readingSourceToc(String name) {
    return '正在读取 $name 的目录';
  }

  @override
  String switchedSource(String name, String title, String chapter, int offset) {
    return '已换源到 $name：$title · $chapter（offset $offset）';
  }

  @override
  String switchSourceFailed(String error) {
    return '换源失败：$error';
  }

  @override
  String get reading => '正在读取';

  @override
  String get chapterNotInToc => '原章节已不在目录中，进度仍保留，请选择章节';

  @override
  String get searching => '正在搜索';

  @override
  String booksFound(int count) {
    return '找到 $count 本书';
  }

  @override
  String get readingDetailsAndToc => '正在读取详情和完整目录';

  @override
  String addedToShelf(String title) {
    return '已加入书架：$title';
  }

  @override
  String addToShelfFailed(String error) {
    return '加入书架失败：$error';
  }

  @override
  String get searchResults => '搜索结果';

  @override
  String get inShelf => '已在书架';

  @override
  String get backToSearchResults => '返回搜索结果';

  @override
  String loginSourceTitle(String name) {
    return '登录书源：$name';
  }

  @override
  String get loginUiEmpty => '该书源的 loginUi 没有可显示的登录界面。';

  @override
  String readLoginInfoFailed(String message) {
    return '读取登录信息失败：$message';
  }

  @override
  String get loginInfoUnavailable =>
      '无法保存登录信息：安装标识不足以生成 AES 密钥（BaseSource.kt:180-192）';

  @override
  String loginError(String message) {
    return '登录出错：$message';
  }

  @override
  String buttonExecuted(String name) {
    return '已执行“$name”';
  }

  @override
  String buttonFailed(String name, String message) {
    return '“$name”执行失败：$message';
  }

  @override
  String get loginHeaderTitle => '登录头部信息';

  @override
  String get noLoginHeader => '（没有保存登录头部信息）';

  @override
  String get copy => '复制';

  @override
  String get close => '关闭';

  @override
  String get loginHeaderCleared => '已清除登录头部信息';

  @override
  String get loginHeaderAction => '登录头部';

  @override
  String get removeLoginHeader => '清除登录头部';

  @override
  String get confirm => '确定';

  @override
  String get certificateFailedTitle => '证书校验失败';

  @override
  String certificateFailedBody(String name, String host, String reason) {
    return '书源“$name”访问 $host 时，TLS 证书校验失败：$reason。\n\n继续访问可能让你的连接被窃听或篡改。是否仅为此书源记住此次例外？';
  }

  @override
  String get unsafeContinue => '继续（不安全）';

  @override
  String get positionSaved => '阅读位置已保存';

  @override
  String get savePosition => '保存位置';

  @override
  String cannotRead(String error) {
    return '无法读取：$error';
  }

  @override
  String get previousPage => '上一页';

  @override
  String get nextPage => '下一页';

  @override
  String get hatchImageTitle => '书源请求显示验证码图片';

  @override
  String get hatchPageTitle => '书源请求在应用内显示页面';

  @override
  String hatchPageBodyImage(String name, String url, String wait) {
    return '书源“$name”请求显示下面的验证码图片：\n\n$url\n\n$wait\n页面或图片由该书源指定，可能看起来像该网站的登录页。只有你信任该书源时才继续。';
  }

  @override
  String hatchPageBodyPage(String name, String url, String wait) {
    return '书源“$name”请求在应用内打开下面的地址：\n\n$url\n\n$wait\n页面或图片由该书源指定，可能看起来像该网站的登录页。只有你信任该书源时才继续。';
  }

  @override
  String get hatchWaits => '书源会一直等待你的操作，最长 5 分钟。';

  @override
  String get hatchDoesNotWait => '页面显示后，书源不会等待。';

  @override
  String get hatchShowImage => '显示图片';

  @override
  String get hatchOpenPage => '打开页面';

  @override
  String get hatchCodeTitle => '验证码';

  @override
  String hatchSource(String name) {
    return '书源：$name';
  }

  @override
  String hatchImageFailed(String failure) {
    return '图片加载失败：$failure';
  }

  @override
  String get hatchAnswer => '验证结果';

  @override
  String get hatchPageRoute => '书源页面';

  @override
  String get done => '完成';
}

/// The translations for Chinese, as used in Hong Kong, using the Han script (`zh_Hant_HK`).
class AppLocalizationsZhHantHk extends AppLocalizationsZh {
  AppLocalizationsZhHantHk() : super('zh_Hant_HK');

  @override
  String get shelfTitle => '書架';

  @override
  String get navLocalLibrary => '本地書庫';

  @override
  String get navMigration => '遷移';

  @override
  String get actionPreciseSearch => '精確搜尋';

  @override
  String get actionSourceTrial => '書源試讀';

  @override
  String get readerScriptTitle => '中文轉換';

  @override
  String get actionInterfaceLanguage => '界面語言';

  @override
  String get shelfSubtitle => 'Windows-first MVP · 共享書源契約驗證台';

  @override
  String get controlledSourceTitle => 'Wayfinder 受控書源';

  @override
  String get controlledSourceDescription => '用於驗證搜尋、書籍信息、目錄和正文的最小鏈路。';

  @override
  String get notRunYet => '尚未運行';

  @override
  String get runControlledSource => '運行受控書源';

  @override
  String get stageSearch => '搜尋';

  @override
  String get stageBookInfo => '書籍信息';

  @override
  String get stageTableOfContents => '目錄';

  @override
  String get stageContent => '正文';

  @override
  String get openingSpaceStore => '正在打開空間存儲…';

  @override
  String spaceStoreUnavailable(String error) {
    return '空間存儲不可用：$error';
  }

  @override
  String legacyImportFailed(String error) {
    return '舊數據導入失敗：$error';
  }

  @override
  String get migratedBooksTitle => '已遷移書籍';

  @override
  String needsRelinkOffset(int offset) {
    return '需要重新關聯本地文件 · offset：$offset';
  }

  @override
  String migratedProgressOffset(int offset) {
    return '遷移進度 offset：$offset';
  }

  @override
  String get localBooksTitle => '本地書';

  @override
  String progressOffset(int offset) {
    return '進度 offset：$offset';
  }

  @override
  String get requestTraceTitle => '請求 trace';

  @override
  String get contractNotice =>
      '當前階段只運行受控 fixture。fjs 的 host callback 生命週期和不可信書源隔離仍是明確門禁；Windows MVP 不代表五平台兼容性已完成。';

  @override
  String get noRootFolder => '尚未授權目錄';

  @override
  String currentFolder(String path) {
    return '當前位置：$path';
  }

  @override
  String currentFolderRelink(String path) {
    return '當前位置：$path（目錄不可用，請重新選擇根目錄）';
  }

  @override
  String get chooseRootFolder => '選擇根目錄';

  @override
  String get goUp => '返回上級';

  @override
  String get scanRecursively => '遞歸掃描當前目錄';

  @override
  String get addToShelf => '顯式加入書架';

  @override
  String get addEntryToShelf => '加入書架';

  @override
  String get folder => '資料夾';

  @override
  String get textFile => 'TXT/Markdown 文件';

  @override
  String get openFolder => '打開資料夾';

  @override
  String get scanEmpty => '掃描結果為空';

  @override
  String rootSelected(String name) {
    return '已選擇根目錄：$name';
  }

  @override
  String scanFinished(int count) {
    return '遞歸掃描完成：發現 $count 個 TXT/Markdown 文件';
  }

  @override
  String get noNewFiles => '沒有新的文件加入書架';

  @override
  String get fileAlreadyOnShelf => '該文件已經在書架中';

  @override
  String fileAdded(String title) {
    return '已加入 $title';
  }

  @override
  String shelfLocalBookCount(int count) {
    return '書架已加入 $count 本本地書';
  }

  @override
  String filesAdded(int count) {
    return '已顯式加入 $count 本書';
  }

  @override
  String get spaceStoreTitle => '空間存儲';

  @override
  String get notCreatedYet => '尚未創建';

  @override
  String get opening => '正在打開…';

  @override
  String importedNow(String at, String summary) {
    return '本次導入舊數據（$at）：$summary';
  }

  @override
  String get nothingToImport => '沒有可導入的舊數據';

  @override
  String alreadyImported(String at, String summary) {
    return '已在 $at 導入過：$summary，本次未重複導入';
  }

  @override
  String get migrationIntro =>
      '選擇 Legado 的備份 ZIP（推薦）或 JSON 文件，先做導入預覽並報告無法遷移的數據。';

  @override
  String get chooseLegadoBackup => '選擇 Legado 備份';

  @override
  String get importPreviewDone => '導入預覽完成';

  @override
  String get importedSourcesTitle => '已導入書源';

  @override
  String get sourceActions => '書源操作';

  @override
  String get loginAction => '登錄';

  @override
  String get editSourceUrlAction => '修改書源 URL';

  @override
  String get deleteSource => '刪除書源';

  @override
  String get urlMissing => '未提供 URL';

  @override
  String get importPreviewTitle => '導入預覽';

  @override
  String previewSources(int count) {
    return 'Book Sources：$count';
  }

  @override
  String previewBooks(int count) {
    return '書架：$count';
  }

  @override
  String previewProgress(int count) {
    return '閲讀進度：$count';
  }

  @override
  String deleteSourceQuestion(String name, String ref) {
    return '刪除書源「$name」？（$ref）\n\n它的緩存、變量、寫入的 Cookie 和已確認的證書例外會一起清理，不能撤銷。書架上由它加入的書會保留（標記為書源已刪除），重新導入同一 URL 的書源即可繼續閲讀。';
  }

  @override
  String get cancel => '取消';

  @override
  String get delete => '刪除';

  @override
  String get save => '保存';

  @override
  String sourceDeleted(String name) {
    return '已刪除書源：$name';
  }

  @override
  String deleteSourceFailed(String error) {
    return '刪除書源失敗：$error';
  }

  @override
  String editSourceUrlTitle(String name) {
    return '修改書源 URL：$name';
  }

  @override
  String get sourceUrlEmpty => '書源 URL 不能為空';

  @override
  String sourceUrlTaken(String url) {
    return '已存在 URL 相同的書源：$url';
  }

  @override
  String editSourceUrlFailed(String error) {
    return '修改書源 URL 失敗：$error';
  }

  @override
  String sourceUrlChanged(String from, String to) {
    return '已修改書源 URL：$from → $to';
  }

  @override
  String sourceNotFound(String ref) {
    return '找不到書源：$ref';
  }

  @override
  String sourceLoggedIn(String name) {
    return '已登錄書源：$name';
  }

  @override
  String get sourceTrialIntro =>
      '搜尋後選書，再查看目錄和正文。當前支持速讀谷及就愛文學所用的部分規則；登錄（loginUrl / loginUi / loginCheckJs）已支持，遠程共享腳本庫尚未支持。';

  @override
  String get chooseSourceAndKeyword => '選擇書源並輸入關鍵詞。';

  @override
  String loadSourceFailed(String error) {
    return '載入失敗：$error';
  }

  @override
  String get sourceJsonRequired => '請選擇 Legado 單個書源或書源數組 JSON';

  @override
  String sourcesLoaded(int count) {
    return '已載入 $count 個書源，僅用於本次試讀';
  }

  @override
  String readSourceFailed(String message) {
    return '讀取失敗：$message';
  }

  @override
  String get enterKeyword => '請輸入關鍵詞。';

  @override
  String get noOnlineReading => '尚無在線閲讀記錄';

  @override
  String get lastReadSourceDeleted => '上次閲讀的書源已刪除，重新導入同一 URL 的書源後可以繼續。';

  @override
  String resumeFailed(String error) {
    return '恢復失敗：$error';
  }

  @override
  String get continueLastReading => '繼續上次閲讀';

  @override
  String get shuduguLoaded => '已載入速讀谷，點擊搜尋後選擇書籍';

  @override
  String get useShuduguSource => '使用速讀谷書源';

  @override
  String get chooseSourceJson => '選擇書源 JSON';

  @override
  String get searchKeyword => '搜尋關鍵詞';

  @override
  String get search => '搜尋';

  @override
  String get followSystemLanguage => '跟隨系統語言';

  @override
  String get scriptFollowInstallation => '跟隨全局設置';

  @override
  String get scriptSimplified => '簡體';

  @override
  String get scriptTraditionalTaiwan => '繁體（台灣）';

  @override
  String get scriptTraditionalHongKong => '繁體（香港）';

  @override
  String get scriptTraditionalGeneric => '繁體（通用）';

  @override
  String get scriptNone => '不轉換';

  @override
  String get describeSimplified => '簡體（大陸用詞）';

  @override
  String get readerScriptDefault =>
      '默認跟隨系統語言：zh-CN → 簡體（大陸用詞），zh-TW → 繁體（台灣），zh-HK → 繁體（香港），其他語言 → 不轉換。';

  @override
  String systemLocaleLine(String tag) {
    return '當前系統語言：$tag';
  }

  @override
  String effectiveLine(String value) {
    return '當前生效：$value';
  }

  @override
  String get installationSettings => '安裝設置';

  @override
  String get loading => '正在讀取…';

  @override
  String bookOverride(String title) {
    return '本書覆蓋：$title';
  }

  @override
  String readSettingsFailed(String error) {
    return '讀取設置失敗：$error';
  }

  @override
  String saveSettingsFailed(String error) {
    return '保存設置失敗：$error';
  }

  @override
  String get interfaceLanguageIntro => '界面語言只換界面自己的文字。書籍內容的字形由「中文轉換」決定，兩者互不影響。';

  @override
  String get languageSimplified => '簡體中文';

  @override
  String get languageTraditionalTaiwan => '繁體中文（台灣）';

  @override
  String get languageTraditionalHongKong => '繁體中文（香港）';

  @override
  String get languageEnglish => 'English';

  @override
  String get interfaceLanguageFollowHint =>
      '跟隨系統：zh-CN → 簡體中文，zh-TW/zh-HK → 繁體中文，其他語言 → English。';

  @override
  String get onlineShelfTitle => '在線書架';

  @override
  String readOnlineShelfFailed(String error) {
    return '讀取在線書架失敗：$error';
  }

  @override
  String get invalidBookUrl => '請輸入有效的 http(s) 書籍鏈接';

  @override
  String get noSourceMatchesUrl => '沒有匹配此鏈接的書源';

  @override
  String get chooseSource => '選擇書源';

  @override
  String openBookUrlFailed(String error) {
    return '打開鏈接失敗：$error';
  }

  @override
  String operationFailedShelfKept(String error) {
    return '操作失敗，書架和進度仍保留：$error';
  }

  @override
  String get bookUrl => '書籍鏈接';

  @override
  String get openBookUrl => '打開書籍鏈接';

  @override
  String get retry => '重試';

  @override
  String get shelfFromSourceHint => '從書源搜尋結果或詳情頁加入書架。';

  @override
  String get sourceDeletedKept => '書源已刪除 · 保留書目與進度';

  @override
  String get notReadYet => '尚未閲讀';

  @override
  String get continueLastChapter => '繼續上次章節';

  @override
  String get bookActions => '書籍操作';

  @override
  String get updateTableOfContents => '更新目錄';

  @override
  String get switchSource => '換源';

  @override
  String get removeFromShelf => '移出書架（保留進度）';

  @override
  String replaceRulesFailed(String error) {
    return '替換規則讀取失敗：$error';
  }

  @override
  String saveProgressFailed(String error) {
    return '進度保存失敗：$error';
  }

  @override
  String chapterLoadFailed(String error) {
    return '章節讀取失敗：$error';
  }

  @override
  String get closeTableOfContents => '關閉目錄';

  @override
  String get tableOfContentsAction => '目錄';

  @override
  String tableOfContentsCount(int count) {
    return '目錄 · $count 章';
  }

  @override
  String get previousChapter => '上一章';

  @override
  String get reloadChapter => '重新加載';

  @override
  String get nextChapter => '下一章';

  @override
  String get preciseSearchTitle => '精確搜尋';

  @override
  String switchSourceTitle(String title) {
    return '換源：$title';
  }

  @override
  String currentSourceLine(String name, int offset) {
    return '當前書源：$name · 進度 offset $offset';
  }

  @override
  String get searchedSources => '搜尋的書源';

  @override
  String get bookName => '書名';

  @override
  String get authorName => '作者';

  @override
  String get mustMatchAuthor => '結果必須包含作者（凍結的 changeSourceCheckAuthor）';

  @override
  String sourceErrorLine(String name, String failure) {
    return '$name 出錯：$failure';
  }

  @override
  String get noAuthor => '（無作者）';

  @override
  String get exactMatch => '精確匹配';

  @override
  String get readingSources => '正在讀取書源';

  @override
  String get noSourcesInSpace => '空間裏還沒有書源';

  @override
  String get chooseSourcesToSearch => '選擇書源，輸入書名後搜尋';

  @override
  String loadSourcesFailed(String error) {
    return '讀取書源失敗：$error';
  }

  @override
  String get enterBookName => '請輸入書名';

  @override
  String get chooseSourcesToSearchStatus => '請選擇要搜尋的書源';

  @override
  String searchingSources(int count) {
    return '正在搜尋 $count 個書源';
  }

  @override
  String searchingSource(Object index, Object name, Object total) {
    return '正在搜尋 $name（$index/$total）';
  }

  @override
  String searchFailed(String error) {
    return '搜尋失敗：$error';
  }

  @override
  String noResults(String name, String author) {
    return '沒有搜尋到<$name>$author';
  }

  @override
  String noResultsWithFailures(String name, String author, int count) {
    return '沒有搜尋到<$name>$author（$count 個書源出錯）';
  }

  @override
  String candidatesFound(int count, int exact) {
    return '候選 $count 本，其中精確匹配 $exact 本';
  }

  @override
  String readingSourceToc(String name) {
    return '正在讀取 $name 的目錄';
  }

  @override
  String switchedSource(String name, String title, String chapter, int offset) {
    return '已換源到 $name：$title · $chapter（offset $offset）';
  }

  @override
  String switchSourceFailed(String error) {
    return '換源失敗：$error';
  }

  @override
  String get reading => '正在讀取';

  @override
  String get chapterNotInToc => '原章節已不在目錄中，進度仍保留，請選擇章節';

  @override
  String get searching => '正在搜尋';

  @override
  String booksFound(int count) {
    return '找到 $count 本書';
  }

  @override
  String get readingDetailsAndToc => '正在讀取詳情和完整目錄';

  @override
  String addedToShelf(String title) {
    return '已加入書架：$title';
  }

  @override
  String addToShelfFailed(String error) {
    return '加入書架失敗：$error';
  }

  @override
  String get searchResults => '搜尋結果';

  @override
  String get inShelf => '已在書架';

  @override
  String get backToSearchResults => '返回搜尋結果';

  @override
  String loginSourceTitle(String name) {
    return '登錄書源：$name';
  }

  @override
  String get loginUiEmpty => '該書源的 loginUi 沒有可顯示的登錄界面。';

  @override
  String readLoginInfoFailed(String message) {
    return '讀取登錄信息失敗：$message';
  }

  @override
  String get loginInfoUnavailable =>
      '無法保存登錄信息：安裝標識不足以生成 AES 密鑰（BaseSource.kt:180-192）';

  @override
  String loginError(String message) {
    return '登錄出錯：$message';
  }

  @override
  String buttonExecuted(String name) {
    return '已執行「$name」';
  }

  @override
  String buttonFailed(String name, String message) {
    return '「$name」執行失敗：$message';
  }

  @override
  String get loginHeaderTitle => '登錄頭部信息';

  @override
  String get noLoginHeader => '（沒有保存登錄頭部信息）';

  @override
  String get copy => '複製';

  @override
  String get close => '關閉';

  @override
  String get loginHeaderCleared => '已清除登錄頭部信息';

  @override
  String get loginHeaderAction => '登錄頭部';

  @override
  String get removeLoginHeader => '清除登錄頭部';

  @override
  String get confirm => '確定';

  @override
  String get certificateFailedTitle => '證書校驗失敗';

  @override
  String certificateFailedBody(String name, String host, String reason) {
    return '書源「$name」訪問 $host 時，TLS 證書校驗失敗：$reason。\n\n繼續訪問可能讓你的連接被竊聽或篡改。是否僅為此書源記住此次例外？';
  }

  @override
  String get unsafeContinue => '繼續（不安全）';

  @override
  String get positionSaved => '閲讀位置已保存';

  @override
  String get savePosition => '保存位置';

  @override
  String cannotRead(String error) {
    return '無法讀取：$error';
  }

  @override
  String get previousPage => '上一頁';

  @override
  String get nextPage => '下一頁';

  @override
  String get hatchImageTitle => '書源請求顯示驗證碼圖片';

  @override
  String get hatchPageTitle => '書源請求在應用內顯示頁面';

  @override
  String hatchPageBodyImage(String name, String url, String wait) {
    return '書源「$name」請求顯示下面的驗證碼圖片：\n\n$url\n\n$wait\n頁面或圖片由該書源指定，可能看起來像該網站的登錄頁。只有你信任該書源時才繼續。';
  }

  @override
  String hatchPageBodyPage(String name, String url, String wait) {
    return '書源「$name」請求在應用內打開下面的地址：\n\n$url\n\n$wait\n頁面或圖片由該書源指定，可能看起來像該網站的登錄頁。只有你信任該書源時才繼續。';
  }

  @override
  String get hatchWaits => '書源會一直等待你的操作，最長 5 分鐘。';

  @override
  String get hatchDoesNotWait => '頁面顯示後，書源不會等待。';

  @override
  String get hatchShowImage => '顯示圖片';

  @override
  String get hatchOpenPage => '打開頁面';

  @override
  String get hatchCodeTitle => '驗證碼';

  @override
  String hatchSource(String name) {
    return '書源：$name';
  }

  @override
  String hatchImageFailed(String failure) {
    return '圖片加載失敗：$failure';
  }

  @override
  String get hatchAnswer => '驗證結果';

  @override
  String get hatchPageRoute => '書源頁面';

  @override
  String get done => '完成';
}

/// The translations for Chinese, as used in Taiwan, using the Han script (`zh_Hant_TW`).
class AppLocalizationsZhHantTw extends AppLocalizationsZh {
  AppLocalizationsZhHantTw() : super('zh_Hant_TW');

  @override
  String get shelfTitle => '書架';

  @override
  String get navLocalLibrary => '本地書庫';

  @override
  String get navMigration => '遷移';

  @override
  String get actionPreciseSearch => '精確搜尋';

  @override
  String get actionSourceTrial => '書源試讀';

  @override
  String get readerScriptTitle => '中文轉換';

  @override
  String get actionInterfaceLanguage => '介面語言';

  @override
  String get shelfSubtitle => 'Windows-first MVP · 共享書源契約驗證臺';

  @override
  String get controlledSourceTitle => 'Wayfinder 受控書源';

  @override
  String get controlledSourceDescription => '用於驗證搜尋、書籍資訊、目錄和正文的最小鏈路。';

  @override
  String get notRunYet => '尚未執行';

  @override
  String get runControlledSource => '執行受控書源';

  @override
  String get stageSearch => '搜尋';

  @override
  String get stageBookInfo => '書籍資訊';

  @override
  String get stageTableOfContents => '目錄';

  @override
  String get stageContent => '正文';

  @override
  String get openingSpaceStore => '正在開啟空間儲存…';

  @override
  String spaceStoreUnavailable(String error) {
    return '空間儲存不可用：$error';
  }

  @override
  String legacyImportFailed(String error) {
    return '舊資料匯入失敗：$error';
  }

  @override
  String get migratedBooksTitle => '已遷移書籍';

  @override
  String needsRelinkOffset(int offset) {
    return '需要重新關聯本地檔案 · offset：$offset';
  }

  @override
  String migratedProgressOffset(int offset) {
    return '遷移進度 offset：$offset';
  }

  @override
  String get localBooksTitle => '本地書';

  @override
  String progressOffset(int offset) {
    return '進度 offset：$offset';
  }

  @override
  String get requestTraceTitle => '請求 trace';

  @override
  String get contractNotice =>
      '當前階段只執行受控 fixture。fjs 的 host callback 生命週期和不可信書源隔離仍是明確門禁；Windows MVP 不代表五平臺相容性已完成。';

  @override
  String get noRootFolder => '尚未授權目錄';

  @override
  String currentFolder(String path) {
    return '當前位置：$path';
  }

  @override
  String currentFolderRelink(String path) {
    return '當前位置：$path（目錄不可用，請重新選擇根目錄）';
  }

  @override
  String get chooseRootFolder => '選擇根目錄';

  @override
  String get goUp => '返回上級';

  @override
  String get scanRecursively => '遞迴掃描當前目錄';

  @override
  String get addToShelf => '顯式加入書架';

  @override
  String get addEntryToShelf => '加入書架';

  @override
  String get folder => '資料夾';

  @override
  String get textFile => 'TXT/Markdown 檔案';

  @override
  String get openFolder => '開啟資料夾';

  @override
  String get scanEmpty => '掃描結果為空';

  @override
  String rootSelected(String name) {
    return '已選擇根目錄：$name';
  }

  @override
  String scanFinished(int count) {
    return '遞迴掃描完成：發現 $count 個 TXT/Markdown 檔案';
  }

  @override
  String get noNewFiles => '沒有新的檔案加入書架';

  @override
  String get fileAlreadyOnShelf => '該檔案已經在書架中';

  @override
  String fileAdded(String title) {
    return '已加入 $title';
  }

  @override
  String shelfLocalBookCount(int count) {
    return '書架已加入 $count 本本地書';
  }

  @override
  String filesAdded(int count) {
    return '已顯式加入 $count 本書';
  }

  @override
  String get spaceStoreTitle => '空間儲存';

  @override
  String get notCreatedYet => '尚未建立';

  @override
  String get opening => '正在開啟…';

  @override
  String importedNow(String at, String summary) {
    return '本次匯入舊資料（$at）：$summary';
  }

  @override
  String get nothingToImport => '沒有可匯入的舊資料';

  @override
  String alreadyImported(String at, String summary) {
    return '已在 $at 匯入過：$summary，本次未重複匯入';
  }

  @override
  String get migrationIntro =>
      '選擇 Legado 的備份 ZIP（推薦）或 JSON 檔案，先做匯入預覽並報告無法遷移的資料。';

  @override
  String get chooseLegadoBackup => '選擇 Legado 備份';

  @override
  String get importPreviewDone => '匯入預覽完成';

  @override
  String get importedSourcesTitle => '已匯入書源';

  @override
  String get sourceActions => '書源操作';

  @override
  String get loginAction => '登入';

  @override
  String get editSourceUrlAction => '修改書源 URL';

  @override
  String get deleteSource => '刪除書源';

  @override
  String get urlMissing => '未提供 URL';

  @override
  String get importPreviewTitle => '匯入預覽';

  @override
  String previewSources(int count) {
    return 'Book Sources：$count';
  }

  @override
  String previewBooks(int count) {
    return '書架：$count';
  }

  @override
  String previewProgress(int count) {
    return '閱讀進度：$count';
  }

  @override
  String deleteSourceQuestion(String name, String ref) {
    return '刪除書源「$name」？（$ref）\n\n它的快取、變數、寫入的 Cookie 和已確認的證書例外會一起清理，不能撤銷。書架上由它加入的書會保留（標記為書源已刪除），重新匯入同一 URL 的書源即可繼續閱讀。';
  }

  @override
  String get cancel => '取消';

  @override
  String get delete => '刪除';

  @override
  String get save => '儲存';

  @override
  String sourceDeleted(String name) {
    return '已刪除書源：$name';
  }

  @override
  String deleteSourceFailed(String error) {
    return '刪除書源失敗：$error';
  }

  @override
  String editSourceUrlTitle(String name) {
    return '修改書源 URL：$name';
  }

  @override
  String get sourceUrlEmpty => '書源 URL 不能為空';

  @override
  String sourceUrlTaken(String url) {
    return '已存在 URL 相同的書源：$url';
  }

  @override
  String editSourceUrlFailed(String error) {
    return '修改書源 URL 失敗：$error';
  }

  @override
  String sourceUrlChanged(String from, String to) {
    return '已修改書源 URL：$from → $to';
  }

  @override
  String sourceNotFound(String ref) {
    return '找不到書源：$ref';
  }

  @override
  String sourceLoggedIn(String name) {
    return '已登入書源：$name';
  }

  @override
  String get sourceTrialIntro =>
      '搜尋後選書，再檢視目錄和正文。當前支援速讀谷及就愛文學所用的部分規則；登入（loginUrl / loginUi / loginCheckJs）已支援，遠端共享指令碼庫尚未支援。';

  @override
  String get chooseSourceAndKeyword => '選擇書源並輸入關鍵詞。';

  @override
  String loadSourceFailed(String error) {
    return '載入失敗：$error';
  }

  @override
  String get sourceJsonRequired => '請選擇 Legado 單個書源或書源陣列 JSON';

  @override
  String sourcesLoaded(int count) {
    return '已載入 $count 個書源，僅用於本次試讀';
  }

  @override
  String readSourceFailed(String message) {
    return '讀取失敗：$message';
  }

  @override
  String get enterKeyword => '請輸入關鍵詞。';

  @override
  String get noOnlineReading => '尚無線上閱讀記錄';

  @override
  String get lastReadSourceDeleted => '上次閱讀的書源已刪除，重新匯入同一 URL 的書源後可以繼續。';

  @override
  String resumeFailed(String error) {
    return '恢復失敗：$error';
  }

  @override
  String get continueLastReading => '繼續上次閱讀';

  @override
  String get shuduguLoaded => '已載入速讀谷，點選搜尋後選擇書籍';

  @override
  String get useShuduguSource => '使用速讀谷書源';

  @override
  String get chooseSourceJson => '選擇書源 JSON';

  @override
  String get searchKeyword => '搜尋關鍵詞';

  @override
  String get search => '搜尋';

  @override
  String get followSystemLanguage => '跟隨系統語言';

  @override
  String get scriptFollowInstallation => '跟隨全域性設定';

  @override
  String get scriptSimplified => '簡體';

  @override
  String get scriptTraditionalTaiwan => '繁體（臺灣）';

  @override
  String get scriptTraditionalHongKong => '繁體（香港）';

  @override
  String get scriptTraditionalGeneric => '繁體（通用）';

  @override
  String get scriptNone => '不轉換';

  @override
  String get describeSimplified => '簡體（大陸用詞）';

  @override
  String get readerScriptDefault =>
      '預設跟隨系統語言：zh-CN → 簡體（大陸用詞），zh-TW → 繁體（臺灣），zh-HK → 繁體（香港），其他語言 → 不轉換。';

  @override
  String systemLocaleLine(String tag) {
    return '當前系統語言：$tag';
  }

  @override
  String effectiveLine(String value) {
    return '當前生效：$value';
  }

  @override
  String get installationSettings => '安裝設定';

  @override
  String get loading => '正在讀取…';

  @override
  String bookOverride(String title) {
    return '本書覆蓋：$title';
  }

  @override
  String readSettingsFailed(String error) {
    return '讀取設定失敗：$error';
  }

  @override
  String saveSettingsFailed(String error) {
    return '儲存設定失敗：$error';
  }

  @override
  String get interfaceLanguageIntro => '介面語言只換介面自己的文字。書籍內容的字形由「中文轉換」決定，兩者互不影響。';

  @override
  String get languageSimplified => '簡體中文';

  @override
  String get languageTraditionalTaiwan => '繁體中文（臺灣）';

  @override
  String get languageTraditionalHongKong => '繁體中文（香港）';

  @override
  String get languageEnglish => 'English';

  @override
  String get interfaceLanguageFollowHint =>
      '跟隨系統：zh-CN → 簡體中文，zh-TW/zh-HK → 繁體中文，其他語言 → English。';

  @override
  String get onlineShelfTitle => '線上書架';

  @override
  String readOnlineShelfFailed(String error) {
    return '讀取線上書架失敗：$error';
  }

  @override
  String get invalidBookUrl => '請輸入有效的 http(s) 書籍連結';

  @override
  String get noSourceMatchesUrl => '沒有匹配此連結的書源';

  @override
  String get chooseSource => '選擇書源';

  @override
  String openBookUrlFailed(String error) {
    return '開啟連結失敗：$error';
  }

  @override
  String operationFailedShelfKept(String error) {
    return '操作失敗，書架和進度仍保留：$error';
  }

  @override
  String get bookUrl => '書籍連結';

  @override
  String get openBookUrl => '開啟書籍連結';

  @override
  String get retry => '重試';

  @override
  String get shelfFromSourceHint => '從書源搜尋結果或詳情頁加入書架。';

  @override
  String get sourceDeletedKept => '書源已刪除 · 保留書目與進度';

  @override
  String get notReadYet => '尚未閱讀';

  @override
  String get continueLastChapter => '繼續上次章節';

  @override
  String get bookActions => '書籍操作';

  @override
  String get updateTableOfContents => '更新目錄';

  @override
  String get switchSource => '換源';

  @override
  String get removeFromShelf => '移出書架（保留進度）';

  @override
  String replaceRulesFailed(String error) {
    return '替換規則讀取失敗：$error';
  }

  @override
  String saveProgressFailed(String error) {
    return '進度儲存失敗：$error';
  }

  @override
  String chapterLoadFailed(String error) {
    return '章節讀取失敗：$error';
  }

  @override
  String get closeTableOfContents => '關閉目錄';

  @override
  String get tableOfContentsAction => '目錄';

  @override
  String tableOfContentsCount(int count) {
    return '目錄 · $count 章';
  }

  @override
  String get previousChapter => '上一章';

  @override
  String get reloadChapter => '重新載入';

  @override
  String get nextChapter => '下一章';

  @override
  String get preciseSearchTitle => '精確搜尋';

  @override
  String switchSourceTitle(String title) {
    return '換源：$title';
  }

  @override
  String currentSourceLine(String name, int offset) {
    return '當前書源：$name · 進度 offset $offset';
  }

  @override
  String get searchedSources => '搜尋的書源';

  @override
  String get bookName => '書名';

  @override
  String get authorName => '作者';

  @override
  String get mustMatchAuthor => '結果必須包含作者（凍結的 changeSourceCheckAuthor）';

  @override
  String sourceErrorLine(String name, String failure) {
    return '$name 出錯：$failure';
  }

  @override
  String get noAuthor => '（無作者）';

  @override
  String get exactMatch => '精確匹配';

  @override
  String get readingSources => '正在讀取書源';

  @override
  String get noSourcesInSpace => '空間裡還沒有書源';

  @override
  String get chooseSourcesToSearch => '選擇書源，輸入書名後搜尋';

  @override
  String loadSourcesFailed(String error) {
    return '讀取書源失敗：$error';
  }

  @override
  String get enterBookName => '請輸入書名';

  @override
  String get chooseSourcesToSearchStatus => '請選擇要搜尋的書源';

  @override
  String searchingSources(int count) {
    return '正在搜尋 $count 個書源';
  }

  @override
  String searchingSource(Object index, Object name, Object total) {
    return '正在搜尋 $name（$index/$total）';
  }

  @override
  String searchFailed(String error) {
    return '搜尋失敗：$error';
  }

  @override
  String noResults(String name, String author) {
    return '沒有搜尋到<$name>$author';
  }

  @override
  String noResultsWithFailures(String name, String author, int count) {
    return '沒有搜尋到<$name>$author（$count 個書源出錯）';
  }

  @override
  String candidatesFound(int count, int exact) {
    return '候選 $count 本，其中精確匹配 $exact 本';
  }

  @override
  String readingSourceToc(String name) {
    return '正在讀取 $name 的目錄';
  }

  @override
  String switchedSource(String name, String title, String chapter, int offset) {
    return '已換源到 $name：$title · $chapter（offset $offset）';
  }

  @override
  String switchSourceFailed(String error) {
    return '換源失敗：$error';
  }

  @override
  String get reading => '正在讀取';

  @override
  String get chapterNotInToc => '原章節已不在目錄中，進度仍保留，請選擇章節';

  @override
  String get searching => '正在搜尋';

  @override
  String booksFound(int count) {
    return '找到 $count 本書';
  }

  @override
  String get readingDetailsAndToc => '正在讀取詳情和完整目錄';

  @override
  String addedToShelf(String title) {
    return '已加入書架：$title';
  }

  @override
  String addToShelfFailed(String error) {
    return '加入書架失敗：$error';
  }

  @override
  String get searchResults => '搜尋結果';

  @override
  String get inShelf => '已在書架';

  @override
  String get backToSearchResults => '返回搜尋結果';

  @override
  String loginSourceTitle(String name) {
    return '登入書源：$name';
  }

  @override
  String get loginUiEmpty => '該書源的 loginUi 沒有可顯示的登入介面。';

  @override
  String readLoginInfoFailed(String message) {
    return '讀取登入資訊失敗：$message';
  }

  @override
  String get loginInfoUnavailable =>
      '無法儲存登入資訊：安裝標識不足以生成 AES 金鑰（BaseSource.kt:180-192）';

  @override
  String loginError(String message) {
    return '登入出錯：$message';
  }

  @override
  String buttonExecuted(String name) {
    return '已執行「$name」';
  }

  @override
  String buttonFailed(String name, String message) {
    return '「$name」執行失敗：$message';
  }

  @override
  String get loginHeaderTitle => '登入頭部資訊';

  @override
  String get noLoginHeader => '（沒有儲存登入頭部資訊）';

  @override
  String get copy => '複製';

  @override
  String get close => '關閉';

  @override
  String get loginHeaderCleared => '已清除登入頭部資訊';

  @override
  String get loginHeaderAction => '登入頭部';

  @override
  String get removeLoginHeader => '清除登入頭部';

  @override
  String get confirm => '確定';

  @override
  String get certificateFailedTitle => '證書校驗失敗';

  @override
  String certificateFailedBody(String name, String host, String reason) {
    return '書源「$name」訪問 $host 時，TLS 證書校驗失敗：$reason。\n\n繼續訪問可能讓你的連線被竊聽或篡改。是否僅為此書源記住此次例外？';
  }

  @override
  String get unsafeContinue => '繼續（不安全）';

  @override
  String get positionSaved => '閱讀位置已儲存';

  @override
  String get savePosition => '儲存位置';

  @override
  String cannotRead(String error) {
    return '無法讀取：$error';
  }

  @override
  String get previousPage => '上一頁';

  @override
  String get nextPage => '下一頁';

  @override
  String get hatchImageTitle => '書源請求顯示驗證碼圖片';

  @override
  String get hatchPageTitle => '書源請求在應用內顯示頁面';

  @override
  String hatchPageBodyImage(String name, String url, String wait) {
    return '書源「$name」請求顯示下面的驗證碼圖片：\n\n$url\n\n$wait\n頁面或圖片由該書源指定，可能看起來像該網站的登入頁。只有你信任該書源時才繼續。';
  }

  @override
  String hatchPageBodyPage(String name, String url, String wait) {
    return '書源「$name」請求在應用內開啟下面的地址：\n\n$url\n\n$wait\n頁面或圖片由該書源指定，可能看起來像該網站的登入頁。只有你信任該書源時才繼續。';
  }

  @override
  String get hatchWaits => '書源會一直等待你的操作，最長 5 分鐘。';

  @override
  String get hatchDoesNotWait => '頁面顯示後，書源不會等待。';

  @override
  String get hatchShowImage => '顯示圖片';

  @override
  String get hatchOpenPage => '開啟頁面';

  @override
  String get hatchCodeTitle => '驗證碼';

  @override
  String hatchSource(String name) {
    return '書源：$name';
  }

  @override
  String hatchImageFailed(String failure) {
    return '圖片載入失敗：$failure';
  }

  @override
  String get hatchAnswer => '驗證結果';

  @override
  String get hatchPageRoute => '書源頁面';

  @override
  String get done => '完成';
}
