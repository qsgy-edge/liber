# Liber's phrase tables: regional wording → mainland wording

`tw2s.txt` (Taiwanese wording) and `hk2s.txt` (Hong Kong wording) sit on top of
the character table in `../hanlp-tc/` and are what makes a Traditional text read
as *mainland* Simplified rather than as Simplified characters with Taiwanese
words in them (硬碟 → 硬盘, 滑鼠 → 鼠标, 網際網路檔案館 → 互联网档案馆).

## Where they come from

OpenCC's `TWPhrasesRev.txt` and `HKPhrasesRev.txt` (Apache-2.0; the values there
are written in Traditional because OpenCC converts them afterwards, so the build
maps every value through the character table first), minus what the corpus audit
disagreed with, plus the hand decisions:

- `tool/text_engine_prototype/audit_phrases.py` asks the corpus what the
  mainland rendering of the same article actually says where the Taiwan rendering
  has the key, and reports `match` / `differ` / `kept` for every entry.
- `tool/text_engine_prototype/phrase_decisions.tsv` is the human answer: `drop`
  (OpenCC over-reaches or the entry is redundant), `override` (a different
  target), `add` (entries OpenCC does not carry), each with its reason.
- `tool/text_engine_prototype/build_phrases.py` produces the two tables, the
  rejection list next to them (`*-rejected.tsv`) and `build-report.json`.

Nothing here is hand-edited: change the decisions file, re-run the build, and the
tables and the report move together. The crate embeds the results with
`include_str!`, so a table change is a compile-time change.

## What the audit found, in numbers

Of OpenCC's 810 Taiwan entries, 224 occur in the 18 658-sentence Wikipedia
reference set. 38 were dropped and 3 overridden, because the reference disagreed
with OpenCC in almost every occurrence:

| OpenCC | occurrences | reference says | decision |
|---|---|---|---|
| 存檔 → 存盘 | 2 926 | 存档 | dropped in favour of 存档 |
| 檔案 → 文件 | 444 | 档案 (文件 only in 檔案館/檔案系統/檔案伺服器/檔案名稱/純文字檔案) | split into the compound entries |
| 建立 → 创建 | 79 | 建立 (79/79) | dropped |
| 執行 → 运行 | 54 | 执行 | dropped |
| 核心 → 内核 | 45 | 核心 (45/45) | dropped |
| 新增 → 添加 | 32 | 新增 (32/32) | dropped |
| 啟用 → 激活 | 33 | 启用 | dropped |
| 資料 → 数据 | 27 | 资料 | dropped (資料庫 → 数据库 stays) |
| 通訊 → 通信 | 4+ | 通讯 | dropped |
| 指標 → 指针 | 9 | 指标 | dropped |
| 查詢 → 查找 | 8 | 查询 | dropped |

And 34 entries were added: 檔案館 → 档案馆, 檔案系統 → 文件系统, 智慧型 →
智能型, 機車 → 摩托车, 桌球 → 乒乓球, 鐵達尼號 → 泰坦尼克号, 高空彈跳 → 蹦极,
音效卡 → 声卡, 點陣圖 → 位图, 案頭 → 桌面, 非同步 → 异步, 變數 → 变量,
電扶梯 → 自动扶梯, 魔獸紀元 → 魔兽世界, 雪梨 → 悉尼, 公尺 → 米, 公分 → 厘米,
透過 → 通过, 部份 → 部分, 計劃/計畫 → 计划, 『』 → ‘’, and 著 → 着 for the
progressive particle (the zhù words — 著作, 著名, 显著 … — are protected in the
crate's `T2S_EXCLUDE` instead).

## The other direction: `tw.txt` and `hk.txt`

The Traditional targets need the mirror image, and there the tables are OpenCC's
unedited (`TWPhrases` + `TWVariants` → `tw.txt`, `HKPhrases` + `HKVariants` →
`hk.txt`, 859 and 148 entries). They are a *second pass* over the character
table's output rather than entries in it, because OpenCC keys both tables in
Traditional — its own pipeline converts characters first and only then applies
them (軟件 → 軟體, 裏面 → 裡面, 打印機 → 印表機).

They have not been through a corpus audit; the reverse gold sets
(`gold-wikipedia-s2t.jsonl`: 18 653 sentences rendered `zh-cn` against `zh-tw`;
`gold-opencc-s2t.jsonl`: OpenCC's `s2t`/`s2tw`/`s2twp`/`s2hk` cases) measure them
instead, and the numbers say the Taiwan target is the good one:

| candidate | sentence-level exact against the `zh-tw` reference |
|---|---|
| `liber_taiwan` (character table + `tw.txt`) | **67.6 %** |
| OpenCC's `s2twp` | 61.8 % |
| `liber_hongkong` (character table + `hk.txt`) | 53.9 % |
| `liber_generic` (character table only) | 53.8 % |
| the frozen reader | 53.7 % |
| OpenCC's `s2t` | 50.7 % |

On OpenCC's own cases the character table is the weak link: `opencc-s2t` scores
49.4 % against `liber_generic`'s 34.3 %, because HanLP's `s2t` table lacks the
variant characters OpenCC's `STCharacters` carries. Merging the two, or adopting
OpenCC's for this direction, is the next thing to try.

## Licence and provenance

OpenCC is Apache-2.0, so a derived table can ship; `NOTICE` records it. The
audit's `kept`/`differ`/`match` counts live in
`tool/text_engine_prototype/evidence/eval-report.json` and in the audit run's
output; the reference corpus itself (Wikipedia, CC BY-SA 4.0) stays outside the
repository with only its hash recorded.
