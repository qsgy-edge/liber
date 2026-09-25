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
  String get actionAutoChangeSource => '自动换源';

  @override
  String get actionSystemProxy => '使用系统代理';

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
  String get shelfFilterHint => '按书名或作者筛选';

  @override
  String get shelfFilterClear => '清除筛选';

  @override
  String get shelfFilterNoMatch => '没有匹配的书';

  @override
  String shelfFilterShown(int shown, int total) {
    return '显示 $shown / $total';
  }

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
  String get systemProxyLabel => '使用系统代理';

  @override
  String get systemProxyHint =>
      '打开后，本产品自己发出的书源请求按系统的代理配置走（Dart 的默认行为）；关闭时是直连——不经过系统代理，也是这个应用一直以来的行为。手机上 VPN 模式的代理在系统层拦截，应用内绕不开；内置 WebView 页面（webView 请求选项与阅读页）由平台引擎自己处理代理，本开关不改变它们。默认关闭。';

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
  String searchProgress(int results, int answered, int total, String name) {
    return '结果 $results, 当前进度 $answered / $total: $name';
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
  String get autoChangeSourceLabel => '书源已删除时自动换源';

  @override
  String get autoChangeSourceHint =>
      '打开书源已被删除的书时，自动在启用的文本书源里按书名和作者找同一本书，确认能取到正文后换过去；找不到合适书源时，书仍留在书架上。默认开启。';

  @override
  String get autoChangingSource => '正在自动换源';

  @override
  String autoChangeSourceFailed(String error) {
    return '自动换源失败\n$error';
  }

  @override
  String get noSuitableSource => '没有合适书源';

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
  String get readerRestoreRelocated => '文件已改动：阅读位置按锚点重新定位';

  @override
  String get readerRestoreSearched => '文件已改动：阅读位置在文件中重新找到';

  @override
  String get readerRestoreLineIndex => '文件已替换：阅读位置按行号恢复，请检查';

  @override
  String get readerRestorePercentage => '文件已替换：阅读位置按百分比恢复，请检查';

  @override
  String get readerDeletedPosition => '替换规则改写了这一行：阅读位置移到改动处的正文';

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

  @override
  String importFileFailed(String error) {
    return '导入文件失败：$error';
  }

  @override
  String scriptConvertFailed(String error) {
    return '中文转换失败：$error';
  }

  @override
  String legacyOnlineReadingNotImported(String reason) {
    return 'online_reading.json 未导入：$reason（原文件保留）';
  }

  @override
  String get legacyOnlineReadingRecordWithoutSourceUrl =>
      '一条在线阅读记录没有 bookSourceUrl，已跳过';

  @override
  String get legacyOnlineReadingLastReadPointer =>
      '在线阅读记录的“上次阅读”指针没有等价字段，改由最近保存的进度回答';

  @override
  String get legacyLocalBooksNotParsed => 'local_books.json 无法解析，已跳过（原文件保留）';

  @override
  String get legacyLocalBooksWithoutRoot => 'local_books.json 没有根目录，未导入';

  @override
  String get legacyLocalBookBytesExcluded => '本地文件字节不导入；文件缺失的书已标记 needsRelink';

  @override
  String legacyLocalFilesMissing(int count) {
    return '$count 个本地文件已不在原路径';
  }

  @override
  String get legacyMigrationStateNotParsed =>
      'migration_state.json 无法解析，已跳过（原文件保留）';

  @override
  String get legacyMigrationNetworkBookWithoutUrl =>
      '迁移记录里的网络书籍没有 bookSourceUrl，只保留标题与进度';

  @override
  String legacyImportSummary(
    int sources,
    int books,
    int chapters,
    int progress,
    int localFiles,
  ) {
    return '书源 $sources · 书籍 $books · 目录 $chapters · 进度 $progress · 本地文件 $localFiles';
  }

  @override
  String get backupEnvelopeExcludedFamilies => '本地文件字节、Cookie、缓存和下载内容不会从备份中导入';

  @override
  String get backupEnvelopeNoSources => '未发现 Book Source 数据';

  @override
  String get backupEnvelopeNoBooks => '未发现书架数据';

  @override
  String get backupEnvelopeNoProgress => '未发现阅读进度数据';

  @override
  String get backupEnvelopeSourceWithoutUrlOrName => '一条书源既没有 URL 也没有名字，已跳过';

  @override
  String get backupEnvelopeBookWithoutKey => '一条书架记录没有 bookUrl/bookId/name，已跳过';

  @override
  String get backupExcludedCookies => 'Cookie：备份里没有 Cookie 表，登录状态不导入';

  @override
  String get backupExcludedCache => '缓存：备份里没有 Cache 表，书源缓存不导入';

  @override
  String get backupExcludedChapters => '章节：备份里没有 BookChapter 表，目录与章节变量不导入';

  @override
  String get backupExcludedDownloads => '下载内容：备份里没有已下载正文，需要重新抓取';

  @override
  String get backupExcludedLocalBytes => '本地书籍字节：备份里没有书文件，已标记需要重新链接';

  @override
  String backupAndroidPreferences(int count) {
    return 'Android 设置：config.xml 的 $count 项偏好属于 Android 端，不导入';
  }

  @override
  String backupAbsentMember(String member) {
    return '备份没有 $member：对应的数据为空';
  }

  @override
  String backupUnreadMembers(int count, String members) {
    return '备份里还有 $count 个成员没有导入：$members';
  }

  @override
  String backupInvalidSources(int count) {
    return '$count 条书源缺少 URL 或名字，已跳过';
  }

  @override
  String backupInvalidGroups(int count) {
    return '$count 个分组没有名字，已跳过';
  }

  @override
  String backupInvalidBooks(int count) {
    return '$count 条书架记录没有 bookUrl，已跳过';
  }

  @override
  String backupConflictingSources(int count) {
    return '$count 个书源在空间中已存在且内容不同，未替换（替换需要确认）';
  }

  @override
  String backupDuplicateBooks(int count) {
    return '$count 条书架记录的 bookUrl 重复，合并为一条';
  }

  @override
  String backupSystemGroups(int count) {
    return '$count 个系统分组（全部/本地/音频等视图）不导入：它们由书籍类型推导';
  }

  @override
  String backupUnmatchedMasks(int count) {
    return '$count 本书的分组位在 bookGroup.json 里没有对应分组';
  }

  @override
  String backupUnreadBooks(int count) {
    return '$count 本书在备份里没有阅读进度（从未打开），未写进度行';
  }

  @override
  String backupNonTextSources(int count) {
    return '$count 个非文本书源已导入，v1 不执行（ADR 0012）';
  }

  @override
  String backupDroppedCovers(int count) {
    return '$count 个封面指向本地路径，未导入（本地字节不迁移）';
  }

  @override
  String backupDroppedEntries(int count) {
    return '$count 条记录不是 JSON 对象，已跳过';
  }

  @override
  String get backupProgressChapterNameDropped =>
      '阅读进度的章节名没有等价字段，进度只保留章节序号与字符位置';

  @override
  String get backupNoSourceMember => '备份没有 bookSource.json：没有书源导入';

  @override
  String get backupNoGroupMember => '备份没有 bookGroup.json：分组不导入';

  @override
  String replaceRuleUnusable(String name, String reason) {
    return '替换规则「$name」不可用：$reason';
  }

  @override
  String replaceRuleTimedOut(String name, int milliseconds) {
    return '替换规则「$name」超时（$milliseconds 毫秒），已停用';
  }

  @override
  String replaceRuleFailed(String name, String error) {
    return '替换规则「$name」出错：$error';
  }

  @override
  String get runSearching => '正在搜索';

  @override
  String runReading(String name) {
    return '读取 $name';
  }

  @override
  String get runReadingToc => '读取目录';

  @override
  String get runJsonFirstChapterDone => '首章读取完成（JSON 规则子集）';

  @override
  String runFailed(String stage, String error) {
    return '$stage：$error';
  }

  @override
  String get runControlledSearch => '搜索返回 1 本书';

  @override
  String get runControlledBookInfo => '书籍信息已返回';

  @override
  String get runControlledToc => '目录已返回 12 章';

  @override
  String get runControlledContent => '正文已返回';

  @override
  String get runControlledCompleted => 'Windows 受控书源链路完成，4 个阶段均有 trace';

  @override
  String literalCopy(String text) {
    return '$text';
  }
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
  String get actionAutoChangeSource => '自動換源';

  @override
  String get actionSystemProxy => '使用系統代理';

  @override
  String get readerScriptTitle => '中文轉換';

  @override
  String get imageLoadFailed => '圖片加載失敗';

  @override
  String get imageLoading => '圖片加載中…';

  @override
  String get imageEmptyAddress => '圖片地址為空';

  @override
  String get actionInterfaceLanguage => '界面語言';

  @override
  String get shelfSubtitle => 'Windows-first MVP · 共享書源契約驗證台';

  @override
  String get shelfFilterHint => '按書名或作者篩選';

  @override
  String get shelfFilterClear => '清除篩選';

  @override
  String get shelfFilterNoMatch => '沒有匹配的書';

  @override
  String shelfFilterShown(int shown, int total) {
    return '顯示 $shown / $total';
  }

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
  String get systemProxyLabel => '使用系統代理';

  @override
  String get systemProxyHint =>
      '打開後，本產品自己發出的書源請求按系統的代理配置走（Dart 的默認行為）；關閉時是直連——不經過系統代理，也是這個應用一直以來的行為。手機上 VPN 模式的代理在系統層攔截，應用內繞不開；內置 WebView 頁面（webView 請求選項與閲讀頁）由平台引擎自己處理代理，本開關不改變它們。默認關閉。';

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
  String searchProgress(int results, int answered, int total, String name) {
    return '結果 $results, 當前進度 $answered / $total: $name';
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
  String get autoChangeSourceLabel => '書源已刪除時自動換源';

  @override
  String get autoChangeSourceHint =>
      '打開書源已被刪除的書時，自動在啓用的文本書源裏按書名和作者找同一本書，確認能取到正文後換過去；找不到合適書源時，書仍留在書架上。默認開啓。';

  @override
  String get autoChangingSource => '正在自動換源';

  @override
  String autoChangeSourceFailed(String error) {
    return '自動換源失敗\n$error';
  }

  @override
  String get noSuitableSource => '沒有合適書源';

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
  String get readerRestoreRelocated => '文件已改動：閲讀位置按錨點重新定位';

  @override
  String get readerRestoreSearched => '文件已改動：閲讀位置在文件中重新找到';

  @override
  String get readerRestoreLineIndex => '文件已替換：閲讀位置按行號恢復，請檢查';

  @override
  String get readerRestorePercentage => '文件已替換：閲讀位置按百分比恢復，請檢查';

  @override
  String get readerDeletedPosition => '替換規則改寫了這一行：閲讀位置移到改動處的正文';

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

  @override
  String importFileFailed(String error) {
    return '導入文件失敗：$error';
  }

  @override
  String scriptConvertFailed(String error) {
    return '中文轉換失敗：$error';
  }

  @override
  String legacyOnlineReadingNotImported(String reason) {
    return 'online_reading.json 未導入：$reason（原文件保留）';
  }

  @override
  String get legacyOnlineReadingRecordWithoutSourceUrl =>
      '一條在線閲讀記錄沒有 bookSourceUrl，已跳過';

  @override
  String get legacyOnlineReadingLastReadPointer =>
      '在線閲讀記錄的「上次閲讀」指針沒有等價字段，改由最近保存的進度回答';

  @override
  String get legacyLocalBooksNotParsed => 'local_books.json 無法解析，已跳過（原文件保留）';

  @override
  String get legacyLocalBooksWithoutRoot => 'local_books.json 沒有根目錄，未導入';

  @override
  String get legacyLocalBookBytesExcluded => '本地文件字節不導入；文件缺失的書已標記 needsRelink';

  @override
  String legacyLocalFilesMissing(int count) {
    return '$count 個本地文件已不在原路徑';
  }

  @override
  String get legacyMigrationStateNotParsed =>
      'migration_state.json 無法解析，已跳過（原文件保留）';

  @override
  String get legacyMigrationNetworkBookWithoutUrl =>
      '遷移記錄裏的網絡書籍沒有 bookSourceUrl，只保留標題與進度';

  @override
  String legacyImportSummary(
    int sources,
    int books,
    int chapters,
    int progress,
    int localFiles,
  ) {
    return '書源 $sources · 書籍 $books · 目錄 $chapters · 進度 $progress · 本地文件 $localFiles';
  }

  @override
  String get backupEnvelopeExcludedFamilies => '本地文件字節、Cookie、緩存和下載內容不會從備份中導入';

  @override
  String get backupEnvelopeNoSources => '未發現 Book Source 數據';

  @override
  String get backupEnvelopeNoBooks => '未發現書架數據';

  @override
  String get backupEnvelopeNoProgress => '未發現閲讀進度數據';

  @override
  String get backupEnvelopeSourceWithoutUrlOrName => '一條書源既沒有 URL 也沒有名字，已跳過';

  @override
  String get backupEnvelopeBookWithoutKey => '一條書架記錄沒有 bookUrl/bookId/name，已跳過';

  @override
  String get backupExcludedCookies => 'Cookie：備份裏沒有 Cookie 表，登錄狀態不導入';

  @override
  String get backupExcludedCache => '緩存：備份裏沒有 Cache 表，書源緩存不導入';

  @override
  String get backupExcludedChapters => '章節：備份裏沒有 BookChapter 表，目錄與章節變量不導入';

  @override
  String get backupExcludedDownloads => '下載內容：備份裏沒有已下載正文，需要重新抓取';

  @override
  String get backupExcludedLocalBytes => '本地書籍字節：備份裏沒有書文件，已標記需要重新鏈接';

  @override
  String backupAndroidPreferences(int count) {
    return 'Android 設置：config.xml 的 $count 項偏好屬於 Android 端，不導入';
  }

  @override
  String backupAbsentMember(String member) {
    return '備份沒有 $member：對應的數據為空';
  }

  @override
  String backupUnreadMembers(int count, String members) {
    return '備份裏還有 $count 個成員沒有導入：$members';
  }

  @override
  String backupInvalidSources(int count) {
    return '$count 條書源缺少 URL 或名字，已跳過';
  }

  @override
  String backupInvalidGroups(int count) {
    return '$count 個分組沒有名字，已跳過';
  }

  @override
  String backupInvalidBooks(int count) {
    return '$count 條書架記錄沒有 bookUrl，已跳過';
  }

  @override
  String backupConflictingSources(int count) {
    return '$count 個書源在空間中已存在且內容不同，未替換（替換需要確認）';
  }

  @override
  String backupDuplicateBooks(int count) {
    return '$count 條書架記錄的 bookUrl 重複，合併為一條';
  }

  @override
  String backupSystemGroups(int count) {
    return '$count 個系統分組（全部/本地/音頻等視圖）不導入：它們由書籍類型推導';
  }

  @override
  String backupUnmatchedMasks(int count) {
    return '$count 本書的分組位在 bookGroup.json 裏沒有對應分組';
  }

  @override
  String backupUnreadBooks(int count) {
    return '$count 本書在備份裏沒有閲讀進度（從未打開），未寫進度行';
  }

  @override
  String backupNonTextSources(int count) {
    return '$count 個非文本書源已導入，v1 不執行（ADR 0012）';
  }

  @override
  String backupDroppedCovers(int count) {
    return '$count 個封面指向本地路徑，未導入（本地字節不遷移）';
  }

  @override
  String backupDroppedEntries(int count) {
    return '$count 條記錄不是 JSON 對象，已跳過';
  }

  @override
  String get backupProgressChapterNameDropped =>
      '閲讀進度的章節名沒有等價字段，進度只保留章節序號與字符位置';

  @override
  String get backupNoSourceMember => '備份沒有 bookSource.json：沒有書源導入';

  @override
  String get backupNoGroupMember => '備份沒有 bookGroup.json：分組不導入';

  @override
  String replaceRuleUnusable(String name, String reason) {
    return '替換規則「$name」不可用：$reason';
  }

  @override
  String replaceRuleTimedOut(String name, int milliseconds) {
    return '替換規則「$name」超時（$milliseconds 毫秒），已停用';
  }

  @override
  String replaceRuleFailed(String name, String error) {
    return '替換規則「$name」出錯：$error';
  }

  @override
  String get runSearching => '正在搜尋';

  @override
  String runReading(String name) {
    return '讀取 $name';
  }

  @override
  String get runReadingToc => '讀取目錄';

  @override
  String get runJsonFirstChapterDone => '首章讀取完成（JSON 規則子集）';

  @override
  String runFailed(String stage, String error) {
    return '$stage：$error';
  }

  @override
  String get runControlledSearch => '搜尋返回 1 本書';

  @override
  String get runControlledBookInfo => '書籍信息已返回';

  @override
  String get runControlledToc => '目錄已返回 12 章';

  @override
  String get runControlledContent => '正文已返回';

  @override
  String get runControlledCompleted => 'Windows 受控書源鏈路完成，4 個階段均有 trace';

  @override
  String literalCopy(String text) {
    return '$text';
  }
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
  String get actionAutoChangeSource => '自動換源';

  @override
  String get actionSystemProxy => '使用系統代理';

  @override
  String get readerScriptTitle => '中文轉換';

  @override
  String get imageLoadFailed => '圖片載入失敗';

  @override
  String get imageLoading => '圖片載入中…';

  @override
  String get imageEmptyAddress => '圖片地址為空';

  @override
  String get actionInterfaceLanguage => '介面語言';

  @override
  String get shelfSubtitle => 'Windows-first MVP · 共享書源契約驗證臺';

  @override
  String get shelfFilterHint => '按書名或作者篩選';

  @override
  String get shelfFilterClear => '清除篩選';

  @override
  String get shelfFilterNoMatch => '沒有匹配的書';

  @override
  String shelfFilterShown(int shown, int total) {
    return '顯示 $shown / $total';
  }

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
  String get systemProxyLabel => '使用系統代理';

  @override
  String get systemProxyHint =>
      '開啟後，本產品自己發出的書源請求按系統的代理配置走（Dart 的預設行為）；關閉時是直連——不經過系統代理，也是這個應用一直以來的行為。手機上 VPN 模式的代理在系統層攔截，應用內繞不開；內建 WebView 頁面（webView 請求選項與閱讀頁）由平臺引擎自己處理代理，本開關不改變它們。預設關閉。';

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
  String searchProgress(int results, int answered, int total, String name) {
    return '結果 $results, 當前進度 $answered / $total: $name';
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
  String get autoChangeSourceLabel => '書源已刪除時自動換源';

  @override
  String get autoChangeSourceHint =>
      '開啟書源已被刪除的書時，自動在啟用的文本書源裡按書名和作者找同一本書，確認能取到正文後換過去；找不到合適書源時，書仍留在書架上。預設開啟。';

  @override
  String get autoChangingSource => '正在自動換源';

  @override
  String autoChangeSourceFailed(String error) {
    return '自動換源失敗\n$error';
  }

  @override
  String get noSuitableSource => '沒有合適書源';

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
  String get readerRestoreRelocated => '檔案已改動：閱讀位置按錨點重新定位';

  @override
  String get readerRestoreSearched => '檔案已改動：閱讀位置在檔案中重新找到';

  @override
  String get readerRestoreLineIndex => '檔案已替換：閱讀位置按行號恢復，請檢查';

  @override
  String get readerRestorePercentage => '檔案已替換：閱讀位置按百分比恢復，請檢查';

  @override
  String get readerDeletedPosition => '替換規則改寫了這一行：閱讀位置移到改動處的正文';

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

  @override
  String importFileFailed(String error) {
    return '匯入檔案失敗：$error';
  }

  @override
  String scriptConvertFailed(String error) {
    return '中文轉換失敗：$error';
  }

  @override
  String legacyOnlineReadingNotImported(String reason) {
    return 'online_reading.json 未匯入：$reason（原檔案保留）';
  }

  @override
  String get legacyOnlineReadingRecordWithoutSourceUrl =>
      '一條線上閱讀記錄沒有 bookSourceUrl，已跳過';

  @override
  String get legacyOnlineReadingLastReadPointer =>
      '線上閱讀記錄的「上次閱讀」指標沒有等價欄位，改由最近儲存的進度回答';

  @override
  String get legacyLocalBooksNotParsed => 'local_books.json 無法解析，已跳過（原檔案保留）';

  @override
  String get legacyLocalBooksWithoutRoot => 'local_books.json 沒有根目錄，未匯入';

  @override
  String get legacyLocalBookBytesExcluded => '本地檔案位元組不匯入；檔案缺失的書已標記 needsRelink';

  @override
  String legacyLocalFilesMissing(int count) {
    return '$count 個本地檔案已不在原路徑';
  }

  @override
  String get legacyMigrationStateNotParsed =>
      'migration_state.json 無法解析，已跳過（原檔案保留）';

  @override
  String get legacyMigrationNetworkBookWithoutUrl =>
      '遷移記錄裡的網路書籍沒有 bookSourceUrl，只保留標題與進度';

  @override
  String legacyImportSummary(
    int sources,
    int books,
    int chapters,
    int progress,
    int localFiles,
  ) {
    return '書源 $sources · 書籍 $books · 目錄 $chapters · 進度 $progress · 本地檔案 $localFiles';
  }

  @override
  String get backupEnvelopeExcludedFamilies => '本地檔案位元組、Cookie、快取和下載內容不會從備份中匯入';

  @override
  String get backupEnvelopeNoSources => '未發現 Book Source 資料';

  @override
  String get backupEnvelopeNoBooks => '未發現書架資料';

  @override
  String get backupEnvelopeNoProgress => '未發現閱讀進度資料';

  @override
  String get backupEnvelopeSourceWithoutUrlOrName => '一條書源既沒有 URL 也沒有名字，已跳過';

  @override
  String get backupEnvelopeBookWithoutKey => '一條書架記錄沒有 bookUrl/bookId/name，已跳過';

  @override
  String get backupExcludedCookies => 'Cookie：備份裡沒有 Cookie 表，登入狀態不匯入';

  @override
  String get backupExcludedCache => '快取：備份裡沒有 Cache 表，書源快取不匯入';

  @override
  String get backupExcludedChapters => '章節：備份裡沒有 BookChapter 表，目錄與章節變數不匯入';

  @override
  String get backupExcludedDownloads => '下載內容：備份裡沒有已下載正文，需要重新抓取';

  @override
  String get backupExcludedLocalBytes => '本地書籍位元組：備份裡沒有書檔案，已標記需要重新連結';

  @override
  String backupAndroidPreferences(int count) {
    return 'Android 設定：config.xml 的 $count 項偏好屬於 Android 端，不匯入';
  }

  @override
  String backupAbsentMember(String member) {
    return '備份沒有 $member：對應的資料為空';
  }

  @override
  String backupUnreadMembers(int count, String members) {
    return '備份裡還有 $count 個成員沒有匯入：$members';
  }

  @override
  String backupInvalidSources(int count) {
    return '$count 條書源缺少 URL 或名字，已跳過';
  }

  @override
  String backupInvalidGroups(int count) {
    return '$count 個分組沒有名字，已跳過';
  }

  @override
  String backupInvalidBooks(int count) {
    return '$count 條書架記錄沒有 bookUrl，已跳過';
  }

  @override
  String backupConflictingSources(int count) {
    return '$count 個書源在空間中已存在且內容不同，未替換（替換需要確認）';
  }

  @override
  String backupDuplicateBooks(int count) {
    return '$count 條書架記錄的 bookUrl 重複，合併為一條';
  }

  @override
  String backupSystemGroups(int count) {
    return '$count 個系統分組（全部/本地/音訊等檢視）不匯入：它們由書籍型別推導';
  }

  @override
  String backupUnmatchedMasks(int count) {
    return '$count 本書的分組位在 bookGroup.json 裡沒有對應分組';
  }

  @override
  String backupUnreadBooks(int count) {
    return '$count 本書在備份裡沒有閱讀進度（從未開啟），未寫進度行';
  }

  @override
  String backupNonTextSources(int count) {
    return '$count 個非文本書源已匯入，v1 不執行（ADR 0012）';
  }

  @override
  String backupDroppedCovers(int count) {
    return '$count 個封面指向本地路徑，未匯入（本地位元組不遷移）';
  }

  @override
  String backupDroppedEntries(int count) {
    return '$count 條記錄不是 JSON 物件，已跳過';
  }

  @override
  String get backupProgressChapterNameDropped =>
      '閱讀進度的章節名沒有等價欄位，進度只保留章節序號與字元位置';

  @override
  String get backupNoSourceMember => '備份沒有 bookSource.json：沒有書源匯入';

  @override
  String get backupNoGroupMember => '備份沒有 bookGroup.json：分組不匯入';

  @override
  String replaceRuleUnusable(String name, String reason) {
    return '替換規則「$name」不可用：$reason';
  }

  @override
  String replaceRuleTimedOut(String name, int milliseconds) {
    return '替換規則「$name」超時（$milliseconds 毫秒），已停用';
  }

  @override
  String replaceRuleFailed(String name, String error) {
    return '替換規則「$name」出錯：$error';
  }

  @override
  String get runSearching => '正在搜尋';

  @override
  String runReading(String name) {
    return '讀取 $name';
  }

  @override
  String get runReadingToc => '讀取目錄';

  @override
  String get runJsonFirstChapterDone => '首章讀取完成（JSON 規則子集）';

  @override
  String runFailed(String stage, String error) {
    return '$stage：$error';
  }

  @override
  String get runControlledSearch => '搜尋返回 1 本書';

  @override
  String get runControlledBookInfo => '書籍資訊已返回';

  @override
  String get runControlledToc => '目錄已返回 12 章';

  @override
  String get runControlledContent => '正文已返回';

  @override
  String get runControlledCompleted => 'Windows 受控書源鏈路完成，4 個階段均有 trace';

  @override
  String literalCopy(String text) {
    return '$text';
  }
}
