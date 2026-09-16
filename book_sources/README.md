# Book Source 实测与本地回放

导入文件：[`shudugu.json`](shudugu.json)，Legado 书源数组格式。

- 站点：https://www.shudugu.org/（页面品牌为“速读谷”）。
- GET 搜索：`/i/sor.aspx?key={{key}}`，来自网站搜索表单。
- 规则：静态 HTML / `@CSS:`，无需执行站点 JS。
- 目录分页：`#pages a.gr`；正文分页：`.prenext a:matchesOwn(^下一页$)`。正文规则不跟随“下一章”，避免章节串接。
- 无登录、付费、验证码或浏览器验证绕过逻辑。

## 已执行测试

2026-09-09：`tool/ShuduguSourceCheck.java` 读取实际书源 JSON，并使用冻结 Legado 基线相同版本的 **Jsoup 1.16.2** 对线上响应求值。其 `@CSS:`、文本/属性提取及正则替换只覆盖本书源所用规则；它不等于 Android Legado 完整执行器。

关键词：`凡人修仙传`。

| 检查 | 实际结果 |
| --- | --- |
| 搜索 | 1 条，准确命中 |
| 详情 | 书名、作者“忘语”、简介与封面 URL 非空 |
| 目录 | 3 页，2512 条，章节 URL 无重复 |
| 首章 | 第1章 山边小村，4 页，合并后 2482 个 Java UTF-16 code units |
| 次章 | 第2章 青牛镇，4 页，合并后 1995 个 Java UTF-16 code units |
| 正文翻页停止 | 两章均停止在本章末页，没有沿“下一章”继续 |

机器记录：[`shudugu.validation.json`](shudugu.validation.json)，含书源 SHA-256、13 个实际请求 URL、响应字节数/哈希、目录计数、章节正文长度/哈希。仓库不存放抓取的小说全文。

## 验证边界

- **已证实：** 此次线上响应和所用 Jsoup 规则可以完成搜索、详情、全目录以及连续两章正文的提取。
- **未执行：** Android Legado 导入后完整运行（当前 `adb devices` 无设备）；封面图片下载；网站其他作品的遍历。
- **Liber 当前支持：** 现有“书源试读”入口已实现本文件所用 CSS、作者前缀替换、完整目录分页和正文分页，可搜索选书、选择章节、上一章/下一章和保存/恢复首个可见段落的 `textOffset`。这不代表其他 HTML/JS 规则或书源已兼容。
- 本结果是实站补充测试，不是冻结 Legado oracle 的兼容性 verdict；站点结构/可用性后续可能变化。

## Liber Windows 验证（2026-09-09）

- `dart run tool/shudugu_live_check.dart` 通过；[Liber 实站记录](shudugu.liber-validation.json)显示 3 页目录、2512 章及前两章各 4 页正文。输出不保存正文全文。
- 6 个针对性离线测试通过：CSS 规则/段落边界、目录与正文分页/循环拒绝、阅读进度文件顺序写入与恢复、阅读器滚动/章节切换、原有 JSON 子集与错误提示。
- MCP 在 Windows 启动 `integration_test/shudugu_reader_test.dart`，真实请求后操作阅读页、点击下一章、滚动并以新 store 实例读取磁盘记录、重建阅读页。日志输出 `SHUDUGU_NATIVE_PASS chapters=2512 tocPages=3 restoredOffset=404` 和 `All tests passed!`。这验证了读盘/重建恢复，未模拟 OS 崩溃或整个进程重启。Flutter run 的测试回传插件提示缺失，判定依据是原生测试断言和实际日志；它不是 CI 平台测试回传结果。
- 正式应用通过 MCP 重新构建启动；运行时错误检查为空。原有本地书库和迁移 importer 的全套验证不在本次范围内；本次测试使用临时独立状态文件，不写入用户的在线阅读记录。

体验路径：`书源试读 → 使用速读谷书源 → 搜索 → 凡人修仙传 → 章节`。也可用“选择书源 JSON”载入原始文件。下次打开通过“继续上次阅读”恢复。

在线阅读记录：Windows `%APPDATA%/Liber/online_reading.json`。现已按书源 URL + 书籍 URL 保存每本书的独立进度与完整目录，并保留最后阅读历史；不会缓存小说全文，加载正文仍需要网络。旧单书记录可继续读取，只有用户点击“加入书架”才进入正式书架。

## 在线书架阶段

- 搜索条目和详情页均可显式加入书架；重复加入保留章节和段落进度。
- 主书架显示已加入的在线书，点击后直接恢复原章节和段落；已有目录直接从本地加载。
- “更新目录”仅在整套新目录获取成功后替换缓存，保留原章节 URL 与偏移；原章节不再存在时提示选择，不静默重置。
- “移出书架（保留进度）”不会删掉阅读记录；重新加入仍可恢复。
- 文件更新串行化并用临时文件替换；损坏文件拒绝覆盖。原本会写入用户 APPDATA 的旧测试已改用临时目录，完整回归前后用户状态哈希一致。
- 完整 `test/` 回归：18 项通过。含双书进度独立、跨 store 写入、重复加入、移出后待完成写入不重新加入、旧记录升级、损坏文件保护、断网目录更新保留、导航缓存恢复回归。
- Windows 原生双书测试：MCP 运行 `integration_test/shudugu_reader_test.dart`，使用真实《凡人修仙传》和《青山》搜索与目录，操作书架/阅读器并重新实例化 store 和路由。首次运行发现 Navigator 锁定，修复首帧恢复时序后热重启重跑，日志为 `SHUDUGU_TWO_BOOK_PASS firstOffset=404 secondOffset=157 shelfCount=2` / `All tests passed!`。仍非 OS 崩溃测试或 Android 验证。

当前正式书架已支持这一 HTML 路径；历史迁移记录仍是独立展示，不据此声明完整迁移 v1 或 JS 书源兼容。

## 复跑

需要 Java 8+、curl、Jsoup 1.16.2 和 Gson 2.10.1。将依赖 JAR 路径填入 `$jsoupJar` 与 `$gsonJar`，在仓库根目录使用 PowerShell 7 执行：

```powershell
$testClasses = Join-Path $env:TEMP 'liber-shudugu-check'
New-Item -ItemType Directory -Force $testClasses | Out-Null
javac -encoding UTF-8 -cp "$jsoupJar;$gsonJar" -d $testClasses tool/ShuduguSourceCheck.java
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }
java -cp "$testClasses;$jsoupJar;$gsonJar" ShuduguSourceCheck book_sources/shudugu.json book_sources/shudugu.validation.json 凡人修仙传
if ($LASTEXITCODE -ne 0) { throw 'source check failed; inspect validation JSON' }
```

## Windows 同步 runtime 与就爱文学切片（2026-09-12）

本次是未提交工作区上的 Windows 产品切片。源码、DLL 和执行结果摘要见
[`jiuai-runtime-validation.json`](jiuai-runtime-validation.json)。它不是冻结 Legado
兼容性 verdict，也没有改变 ticket 05/14 或其他平台的完成状态。

- `packages/fjs` 保存 MIT 许可证、固定上游 `8195d78…` 的平台构建集成，以及配对的同步 broker/native/FRB 2.12.0 bindings；产品使用相对 path 依赖，保留 FRB content-hash 检查，通过原 cargokit 链构建，未向产品目录手工复制 DLL。
- native 先触发 shutdown 再清理 host；同一 registry 内关闭准入并收割请求；starter 异常会结束请求，cancel 异常在清理后报告；关闭期间排队 eval 不再执行。移除了隐式文件/原生模块 loader；注册模块之外的本地 `.js` import 被拒绝。
- 产品 runtime 同步提供当前切片用到的 `java.connect(...).raw().request().url()` 与有限 HTTP facade；每次 execution 独立取消，source dispatcher 保留跨执行 Cookie。实际接入堆上限、输入/输出及 host I/O 上限，未知 HTTP method 在 I/O 前拒绝。
- HTML pipeline 新增静态 header、POST form、URL 中的同步 JS 表达式，以及样本使用的索引列表/排除、元素链、`textNodes`、替换和正文分页；修正 Dart 重定向覆盖 source User-Agent 的问题。书源试读可将隐式 HTML 规则路由至既有选书和阅读界面。

已执行证据：

| 检查 | 结果 |
| --- | --- |
| 三个旧 broker 缺陷反例 | 修复前 exit 1；修复后通过。取消 callback 故意抛异常仍会产生 FRB panic hook 诊断，但已被捕获，关闭能完成清理并返回结构化错误。正式 runtime 的 callback 自身不向 FRB 抛异常。 |
| 初始化/关闭交错与限制 | 64 次交错通过；关闭后拒绝 eval；伪造取消文字仍是脚本错误；无关后台错误仍报告；8 MiB 原生 heap 限制实测生效。并非穷举竞态或 OS 沙箱证明。 |
| 既有 broker 回归 | 14 组通过，含 8 个独立 engine 重叠、真实 Timer/HTTP 取消、迟到 completion 拒绝、自然退出。 |
| 正式 runtime | 13 项通过，含无限循环超时中断、服务器断连、取消后新 execution 可用、真实边界限额。Windows 构建产物 DLL 复跑通过。 |
| 原始规则本地四阶段 | 12 项通过：两本搜索结果、作者/分类/最新章节/详情、TOC 排除与顺序、两页正文、精确 POST body、7 次请求顺序、每一跳的 source User-Agent。 |
| 普通 `test/` | Dart MCP 26 项通过；相关格式化和静态分析无错误。 |
| Windows 原生 UI | 在真实 app 中选书→详情/目录→第一章两页正文→下一章，新 store 从独立临时文件读回“第二章”；日志 `JIUAI_NATIVE_PASS` 与 `All tests passed!`。MCP `launch_app` 方式仍有 integration_test 结果回传插件警告，使用实际断言、日志和本地结果文件作为证据，不宣称 CI instrumentation 回传成功。 |
| 原始实站补充 | 首次使用 8 秒请求限额，search timeout。后续使用产品默认 30 秒预算：前置 GET 约 10.5 秒返回 502/空正文，POST 搜索约 176 ms 返回 502/空正文，进程自然 exit 1；没有进入 info/TOC/content。直连与环境代理的单独 HTTP 对照均收到 502，HTTPS 在握手阶段失败。站点与网络网关的责任归属未证实。 |
| 冻结 oracle 执行条件补查 | `adb devices -l` 为空，现有 emulator 的 `-list-avds` 也为空；冻结基线仍为 `14dd249…`，未修改基线源码。新四阶段 oracle 当前无 Android 执行宿主，不能用既有 WebView oracle 或本地预期替代。 |

`tool/source_live_check.dart` 现使用产品默认请求预算，并只记录请求序号、method、耗时、状态码和正文长度；不输出源地址、鉴权头或正文。较早 8 秒运行记录保留为历史证据。

[`../test/fixtures/jiuai_replay.json`](../test/fixtures/jiuai_replay.json) 的 `searchUrl`、
`ruleSearch`、`ruleBookInfo`、`ruleToc`、`ruleContent` 与用户样本逐项相同；只替换名称、
端点和静态 header 为去敏本地值。HTML 响应是合成回归数据，**不是 golden**；
冻结 Legado oracle 尚未运行。没有把原始导出中的鉴权值写入项目。

仍未支持/证明：同 runtime 的 host→JS 嵌套及共享 jsLib 对象/闭包、通用 AnalyzeUrl/JS/HTML/XPath、
完整 response facade、冻结 Cookie/redirect 全部语义、恶意 native 崩溃隔离及 Android/iOS/macOS/Linux。
非当前切片的能力不得由本次结果推为通过，猫眼看书尚未实测。

从仓库根目录复跑（PowerShell 7，已安装工程 SDK）：

```powershell
fvm flutter build windows --debug
$dll = (Resolve-Path 'build/windows/x64/runner/Debug/fjs.dll').Path
fvm dart run tool/runtime_gate.dart $dll
fvm dart run tool/broker_lifecycle_regression.dart $dll
fvm dart run tool/jiuai_replay.dart $dll
```

本地试玩需要两个终端。第一个保留 replay server：

```powershell
$reviewSource = Join-Path $env:TEMP 'liber-jiuai-review.json'
fvm dart run tool/jiuai_replay.dart --serve "--source-out=$reviewSource"
```

第二个打开真实产品界面：

```powershell
$reviewSource = Join-Path $env:TEMP 'liber-jiuai-review.json'
fvm flutter run -d windows -t tool/jiuai_review.dart "--dart-define=LIBER_REVIEW_SOURCE=$reviewSource"
```

点击“回放之书”→“第一章”→“下一章”。终端 Ctrl+C 停止各自进程。常规入口仍是
`fvm flutter run -d windows`，从“书源试读”选择 JSON；调试入口没有替换正式主页面。

## Broker 嵌套与生命周期复核（2026-09-14）

本轮继续交接中的 Windows gate，结果与完整命令见
[`broker-runtime-validation.json`](broker-runtime-validation.json)。当前 `master`
的未提交 candidate 使用 DLL `a90bcb31…`；旧 manifest 中 119 个 fjs 源文件哈希
逐项复算一致。本轮只扩展验证工具，没有修改 native runtime 或提升 ticket 状态。

- **已证实**：同一 engine 顺序调用能保留共享闭包；host callback 等待同一 engine 的
  嵌套 eval 时，外层调用在 1 秒观测窗内未完成，`same-runtime-nested` 明确 exit 1。
  关闭后内外 eval 都返回 `JsError_Cancelled`，Dart callback 完成，迟到 completion
  被拒绝。先返回 host 结果的对照能执行排队 eval 并得到 42；它不代表同步嵌套语义通过。
- **推断**：当前 context 内的同步 broker 等待与 callback 重新进入 `context.async_with`
  构成循环等待。下一步需验证在持有上下文的执行线程上处理嵌套请求的方案；不能把延长超时、
  先返回占位结果或另建 engine 当作共享闭包兼容实现。
- **通过的检查**：强化的 64 次 init/close 交错（本轮 init 成功 6 次、Engine error 58 次），
  同时验证关闭后 running=false、拒绝 eval/重新初始化及重复 close；其余三个 lifecycle 检查、
  三个旧 broker 缺陷回归、隐式文件 import 拒绝和 runtime 13 项检查均通过。
  故意抛异常的 callback 仍输出已捕获的 FRB panic-hook 诊断；取消嵌套 starter 还输出
  `dart_fn_handle_output` send 诊断，不宣称 stderr 干净或 callback 内存回收已证明。
- **MCP**：两份变更工具完成 format/analyze（`No errors`），普通测试 28 项通过；
  Windows `tool/cat_eye_driver.dart` 经 launch→DTD connect→Driver health→输入搜索→读取
  “猫眼正文”与“1 章 · 第一章”通过，runtime errors 为 0。该合成 JSON UI 回放不覆盖 broker 嵌套。
- **未证实**：嵌套修复、产品共享 jsLib 语义、穷举竞态/内存回收、恶意代码隔离、冻结 oracle
  以及 Android/iOS/macOS/Linux。本轮没有重查设备，也没有新建 golden。

复现阻塞与对照（第一个命令应返回 exit 1，保持 gate 为 fail）：

```powershell
$dll = (Resolve-Path 'build/windows/x64/runner/Debug/fjs.dll').Path
fvm dart run tool/broker_gate_regression.dart $dll same-runtime-nested
fvm dart run tool/broker_gate_regression.dart $dll same-runtime-queued-release
fvm dart run tool/broker_lifecycle_regression.dart $dll
```


## 已提交状态与请求语义切片（2026-09-15）

上一节记录的是未提交 candidate。当前 `master` 已包含该切片，并由五平台 CI
（`.github/workflows/ci.yml` + `tool/ci_runtime.py`）门禁：Windows、Linux、macOS
跑**同一份**门禁清单——runtime/host/broker 门禁、6 个 `broker_gate_regression` 模式、
`scoped_runtime_gate`/`nested_runtime_gate`、HTML 适配器与两份冻结差分；清单只有一份，
见 `tool/ci_runtime.py`。runtime 命令的日志出现 Dart VM crash marker 即判失败（即使进程退出 0）。
`fiber_runtime_gate` 已随 ADR 0009（#25）删除：Windows fiber 调度器不再存在，
它的断言在票面三张表里逐条记录为保留 / 重新推导 / 删除，见 #25 的评论。

本轮产品改动：

- **阅读页章节标题**：加载下一章时显示目标章节名并标注“载入中…”，失败时回退到已保存章节。
- **请求语义**：书源规则的 `,{...}` URL 选项（`method`/`headers`/`body`/`js`/`retry`）
  在搜索、目录与正文分页规则上生效，`header` 规则支持 `@js:` 与 `<js>`；`charset`、`type`、
  `webView`、`webJs`、`webViewDelayTime`、`serverID` 仍显式拒绝，`java.*` 规则 JS 路径的
  选项、响应字符集解码与关键字替换编码方式（当前统一百分号编码）仍是已记录的缺口。

验证：`flutter test`（41 项，含新增的 URL 选项与 POST 形态单测）、
`python tool/ci_runtime.py windows x86_64-pc-windows-msvc`（15/15）、
CI run `34957069862`（Windows/Linux/macOS 全部命令通过；Linux 一次
`native-heap-limit` 分类抖动，rerun 通过，已记入 map 限制）。
