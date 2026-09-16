# THROWAWAY: Rust text engine, benchmark and conversion decision (ticket #19)

**Verdict, on Windows, with the inputs in the page cache.** The engine the ticket
asks for exists (`packages/fjs/liber_text`, behind the same `cargokit`/FRB native
library as the JavaScript runtime and the HTML adapter) and the numbers it was
asked to beat are beaten. The values below are the committed run
(`evidence/manifest.json`); each engine row ran three times, so its spread is
visible, and a second run of the whole file earlier the same day was faster
across the board (609 ms for the 500 MB pass, 11.6 s for the Dart pass) — the
spread is the machine, not the engine.

| Row | Pass time | Peak RSS | Footprint |
|---|---|---|---|
| **Engine, 500 MB UTF-8** (release, no Dart in the process) | **977 ms** (921 / 977 / 1012) | 6.7 MB | **2.8 MB** |
| Engine, 20 MB GBK | 537 ms (537 / 542 / 537) | 6.8 MB | 2.9 MB |
| Engine, 31.7 MB UTF-8 (the GBK text's twin) | 415 ms | 6.8 MB | 2.8 MB |
| Window read, 20 000 units at offset 100 000 000 of the 500 MB file | **2.5 ms** | 5.2 MB | 1.3 MB |
| Pure-Dart streaming index, same 500 MB file | 15 613 ms | 272 MB | 23.4 MB |
| `File.readAsString()`, same 500 MB file | 3 553 ms | **1 085 MB** | 832 MB |
| The engine through the bridge (release DLL, Dart process) | 1 370 ms | 271 MB | 23.0 MB |
| …through the bridge (debug DLL, what `flutter run` loads) | 12 162 ms | | 8.9× slower |

Targets from `docs/user-data-contract.md` D4/D10: a 500 MB pass under ~1 s and
peak RSS under ~50 MB. **Both hold for the engine itself** (977 ms at the median
of three runs, 6.7 MB of a 50 MB budget); the Dart-side rows show why the work
left Dart: the pure-Dart pass is 16× slower and the decode the reader does today
allocates 832 MB more than the file it reads. That `File.readAsString()` row is
the contract's existing measurement — 2.9 s and ≈ 1 GB — reproduced on this
machine (3.6 s, 1.09 GB). The bridge row is the product's real path and pays a
further ~0.4 s to hand 15 964 anchors across FRB.

**The encoding argument is now a measured row, not a claim.** `dart:convert` has
no GBK decoder: `File.readAsStringSync()` on the 20 MB GBK file fails with
`FileSystemException: Failed to decode data using encoding 'utf-8'`, and decoding
it with `allowMalformed` produces **13 085 856 replacement characters**. The
engine indexes the same file in 537 ms and a window read returns its text.

**The conversion decision (A or B) is A: HanLP 1.x's `tc` tables plus Legado's
exclude list.** The measured difference from the frozen reader, as a share of the
UTF-16 code units and of the lines, on the three corpora below:

| Candidate | novels t2s | modern-TW t2s | modern-CN t2s | novels s2t | modern-TW s2t | modern-CN s2t |
|---|---|---|---|---|---|---|
| **HanLP + exclude (chosen)** | **0.210 % / 16.2 %** | **0.798 % / 25.0 %** | **0.055 % / 2.4 %** | **0.078 %** | **0.023 %** | **0.021 %** |
| OpenCC `t2s` + exclude | 2.466 % / 50.1 % | 1.399 % / 31.3 % | 0.111 % / 3.9 % | 0.856 % | 0.037 % | 0.589 % |
| OpenCC `tw2sp` + exclude | 2.722 % / 60.0 % | 1.085 % / 20.5 % | 0.174 % / 6.2 % | — | — | — |

Every row is the *frozen* reader's output compared against a candidate's, so
smaller is closer to the behaviour this product defines as correct. The two
control rows — the baseline's own tables re-run through this probe's matcher —
reproduce the frozen library **exactly** (0 differing units in every corpus,
2.85 M code units in total), which is what makes the other rows attributable to
the tables rather than to the matcher.

What the divergence is, and what it is not: HanLP's `t2s` table is smaller than
the table the frozen reader carries (the frozen library merges HanLP with
`luhuiguo/chinese-utils` and further phrase tables), so the divergences are
mostly *under-conversion* — a Taiwan word keeps its characters and its word
(檔案 → 档案 rather than 文件, 記憶體 → 记忆体 rather than 内存, 存檔 → 存档
rather than the frozen 存盘), and a handful of characters the frozen table has
learned that HanLP's has not (『』 stays 『』, 姪 stays 姪). The exceptions run the
other way: this product converts 乾 where the frozen reader deliberately does
not, and it keeps 魔戒/桌球/雪梨 verbatim because Legado's own exclude list says
so. OpenCC's divergences are different in kind: it leaves the frozen reader's
punctuation conversion undone (`「」` stays `「」` instead of becoming `“”`;
`tw2sp` even turns `“”` into `「」`), it normalises variants (`爲` → `為`,
`吃` → `喫`, `擡` → `抬`), and its data is compiled into a third-party crate
rather than readable in this repository. ADR 0009 records the decision.

## Accuracy: is the 繁体→简体 output right, not just "like the frozen reader"

The conversion decision above was measured as *agreement with the frozen reader*.
That is a compatibility number, not a quality one. The follow-up question — "is the
Simplified text actually right for a reader who only reads Simplified, word choice
included" — is measured by three more scripts, all re-runnable:

```bash
python tool/text_engine_prototype/make_eval_gold.py            # gold sets (needs the page cache)
conversion_probe/target/release/eval.exe   D:/liber-probe/text-engine/eval/gold-wikipedia.jsonl   packages/fjs/liber_text/assets/hanlp-tc D:/liber-probe/text-engine/opencc-dict   D:/liber-probe/text-engine/eval/out-wikipedia
python tool/text_engine_prototype/score_eval.py
```

- **Two gold sets.** `gold-opencc.jsonl` is OpenCC's own hand-made cases filtered
  to the directions that end in Simplified (174 rows: `t2s` 56, `tw2s` 33, `hk2s`
  22, `tw2sp` 54, `hk2sp` 9, Apache-2.0) — dense in the hard spots, and OpenCC's
  own opinion, so it flatters the candidates built from OpenCC's tables.
  `gold-wikipedia.jsonl` is 18 658 sentences from 45 zh.wikipedia articles rendered
  `variant=zh-tw` and `variant=zh-cn`, aligned line by line and sentence by
  sentence (CC BY-SA 4.0, kept out of the repository; hashes in
  `evidence/gold-manifest.json`). Neither set is an authority: the second is
  MediaWiki's conversion tables' opinion, and it itself leaves 20.5 Traditional
  characters per 1 000 behind — 57× the shipped implementation's 0.36 — because
  its renderer is not a complete character conversion.
- **Nine candidates**: the frozen oracle, the shipped implementation, the HanLP
  tables with and without the exclude list, HanLP plus OpenCC's Taiwan and Hong
  Kong phrase lists (each phrase's value mapped through the character table
  first), and ferrous-opencc's four configurations. `hanlp+exclude` is a control
  and reproduces the shipped implementation exactly on every row.
- **The scorer** reports sentence-level exact matches, errors split into missed /
  wrong / over-converted, and — with no reference involved — how many characters
  in the output are still Traditional, which is what the reader actually sees.
  `evidence/eval-report.md` has the tables and the frequent disagreements;
  `evidence/eval-report.json` has per-row samples.


### From the audit to the shipped tables

The evaluation says *where* the shipped conversion is wrong; two more scripts act
on it, and both are re-runnable:

```bash
python tool/text_engine_prototype/audit_phrases.py --min-total 2   # what the reference says per entry
python tool/text_engine_prototype/build_phrases.py                 # tables + rejection list + report
```

- `audit_phrases.py` takes every entry of OpenCC's Taiwan/Hong Kong phrase lists
  (and Legado's exclude list) and counts, at every occurrence in the reference
  corpus, whether the mainland rendering *matches* the entry, *differs* from it,
  or *keeps* the Taiwan word. The report is what the hand decisions were made on;
  the counts land in `eval-report.json`.
- `phrase_decisions.tsv` is the hand answer — `drop`, `override`, `add`, each with
  its reason — and `build_phrases.py` turns OpenCC's tables plus those decisions
  into `packages/fjs/liber_text/assets/phrases/{tw2s,hk2s}.txt`, the
  `*-rejected.tsv` lists and a `build-report.json`. The crate embeds the results,
  so `cargo test` fails when a table moves without its fixture.

What the audit changed, against the 18 658-sentence Wikipedia set: of OpenCC's 810
Taiwan entries, 224 occur in the corpus; 38 were dropped and 3 overridden
because the reference disagreed in nearly every occurrence (存檔 → 存盘 2 926
times against 存档, 建立 → 创建 79/79 against 建立, 核心 → 内核 45/45, 執行 →
运行, 新增 → 添加, 啟用 → 激活, 資料 → 数据, 通訊 → 通信, 指標 → 指针, 查詢 →
查找, and 檔案 → 文件 split into its compounds). 79 entries were added
(檔案館 → 档案馆, 智慧型 → 智能型, 著 → 着, 公尺 → 米, 『』 → ‘’, …). The reading
conversion then measures:

| | shipped reading conversion | previous implementation | OpenCC's list unedited |
|---|---|---|---|
| sentence-level exact | **72.8 %** | 68.8 % | 64.8 % |
| error positions | **1.01 %** | 1.71 % | 1.92 % |
| converted by the reference, left Traditional | **1 969** | 4 530 | 3 003 |
| Traditional characters left per 1 000 | 0.06 | 0.36 | 0.36 |

The remaining misses are mostly wording where the two references differ among
themselves (資訊 → 信息 against the reference's 资讯), alignment noise on long
sentences, and the `著`/`着` particle in verb+著 compounds the table has not
listed yet.

## What was measured

`verify.py` runs one phase per process — peak RSS is a process number, so a
second phase in the same process could never report a lower peak — and writes
`evidence/windows-text-engine.json` (every row), `evidence/gates.log` (the
commands) and `evidence/manifest.json` (commit, library and input hashes, the
findings above).

- `rust_bench/` is the engine alone: the same crate, no Dart VM. It exists
  because `dart run` reports ≈ 250 MB of Dart VM before the engine does anything,
  which would hide the contract's 50 MB question entirely.
- `text_engine_bench.dart` measures the pure-Dart streaming index (line starts
  and code units in one pass, the row the contract asks for), `readAsString()`,
  a byte-level pass, `dart:convert`'s lossy decode, and the engine through the
  bridge.
- `conversion_probe/` compares conversion tables against the frozen oracle's
  output; its reports are `evidence/conversion-*.json`. Its `opencc_echo` bin
  converts stdin lines with one OpenCC config, which is how the divergence classes
  in ADR 0009 were read out one string at a time.
- `rust_bench/src/bin/probe.rs` is the one-off that found where the pass spent
  its time while it was still 3.4 s: bulk decode floors, the newline scan, the
  trigger scan, and the same pass with and without the chapter rules. It is the
  reason the regex pre-filter and the eight-byte newline scan exist, and it is
  still the tool to reach for if a pass regresses.

## Re-running it

```bash
# 1. Inputs (the 20 MB GBK and UTF-8 files; 500mb.txt already exists).
python tool/text_engine_prototype/make_inputs.py

# 2. Benchmark. --library is the release DLL, --debug-library adds the
#    debug-build rows; both are recorded with their hashes.
cargo build --release --locked --manifest-path packages/fjs/libfjs/Cargo.toml
python tool/text_engine_prototype/verify.py \
  --library packages/fjs/libfjs/target/release/fjs.dll \
  --debug-library packages/fjs/libfjs/target/debug/fjs.dll

# 3. The conversion measurement, from the corpus to the reports.
python tool/text_engine_prototype/fetch_corpus.py            # 254 pages, cached per page
python tool/text_engine_prototype/make_conversion_fixture.py # -> the crate's fixtures
python tool/text_engine_prototype/make_inputs.py
```

The conversion reports were produced with a Java harness that links
`quick-transfer-core` 0.2.16 — the version the frozen snapshot pins — with
Legado's `fixT2sDict` exclude list applied before the first `t2s` call. The
harness is *not* in this repository, for the same reason the other frozen-oracle
harnesses are not (see `NOTICE`): it links the baseline's own libraries. What it
does is four steps, and re-doing them is what re-runs the reports:

1. `javac -encoding UTF-8 -cp <quick-transfer-core-0.2.16.jar> BaselineOracle.java`
   where the jar is the one the frozen snapshot resolves
   (`com.github.liuyueyi.quick-chinese-transfer:quick-transfer-core:0.2.16`,
   sha256 `b9b92d29f36b2d8d36861b054f895fbb5ba16ccaf7b4ad66c83d0af4cd1414f5`).
2. `java -cp <jar>;. BaselineOracle <corpus.txt> <corpus.jsonl>`: one JSON record
   per input line with the line, its `t2s` and its `s2t`, the exclude list loaded
   for `t2s` exactly as `ChineseUtils.kt` loads it.
3. `conversion_probe <corpus.jsonl> <jar-tc-dir> <hanlp-tc-dir> <report.json>`:
   the same longest-match matcher over the baseline's own tables as a control row
   and over each candidate's tables.
4. The reports land in `evidence/conversion-*.json`.

## Corpora

| Corpus | What it is | Size | Provenance |
|---|---|---|---|
| novels | 三國演義 1–120 + 紅樓夢 1–40, Traditional, paragraphs as lines | 887 324 units | `zh.wikisource.org`, revision ids in `corpus-manifest.json`, public domain |
| modern-TW | 45 zh.wikipedia articles rendered `variant=zh-tw` — the modern-Traditional prose with Taiwan vocabulary a classical novel cannot exercise | 984 494 units | `zh.wikipedia.org`, revision ids in `corpus-manifest.json`, CC BY-SA 4.0, **not committed** |
| modern-CN | the same articles rendered `variant=zh-cn` | 983 942 units | as above |

`fetch_corpus.py` caches every page, so a re-run fetches only what changed. The
files live in `D:/liber-probe/text-engine/` beside the measurement session's
`500mb.txt`, not in the repository: only hashes, and word-level diff hunks in the
reports, are committed.

## Two deliberate omissions

- **No `mmap`.** D10 lists a mapped file as one reason the engine is Rust; measured,
  it is not needed for the target. Chunked buffered reads plus the sparse anchors put
  a 500 MB pass at 609 ms and a window read at 1.9 ms, and a window read only ever
  touches the bytes between two anchors.
- **No `t2tw`/`t2hk` tables.** The frozen reader's two conversion settings are `t2s`
  and `s2t` (`ContentProcessor` and `BookChapter` switch on 1 and 2 only), so the two
  tables the crate carries are the two the product needs.

## Not covered

- **Other platforms.** Every row is Windows (a Windows 11 arm64 host running the
  x86_64 toolchain). The engine is platform-independent Rust and CI builds it for
  all five targets, but no other platform ran the benchmark.
- **Cold cache.** The 500 MB rows are page-cache-warm; the record keeps three
  runs per row, and the differences between them are small enough that a cold
  first read is the only thing not separated out.
- **The reader path.** No wiring into the shelf or the reader: #20 fills
  `text_index` and writes progress, #24 moves the library onto the store. This
  ticket measures the engine and gives it a Dart seam.
- **Chapter detection quality.** The default rules find the three chapters of
  `tests/data/chaptered_book.txt` and none in the wiki corpus, which has no
  chapter headings; no claim is made about TXT files whose headings need the
  disabled default rules (回/部/篇/场/话) or a user's own rule.
- **Conversion timing in the app.** The measured conversion row is ~120 ns per
  code unit (1 M units per direction in 242 ms, both directions in one process),
  i.e. well under a millisecond for the few thousand units of a chapter, but no
  reader has converted a chapter yet.
