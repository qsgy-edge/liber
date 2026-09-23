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
}
