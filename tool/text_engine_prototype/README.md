# THROWAWAY: Rust text engine, benchmark and conversion decision (ticket #19)

**Verdict, on Windows, with the inputs in the page cache.** The engine the ticket
asks for exists (`packages/fjs/liber_text`, behind the same `cargokit`/FRB native
library as the JavaScript runtime and the HTML adapter) and the numbers it was
asked to beat are beaten:

| Row | Pass time | Peak RSS | Footprint |
|---|---|---|---|
| **Engine, 500 MB UTF-8** (release, no Dart in the process) | **609 ms** (603/609/617) | 5.7 MB | **2.5 MB** |
| Engine, 20 MB GBK | 384 ms (347/384/385) | 6.8 MB | 2.9 MB |
| Engine, 31.7 MB UTF-8 (the GBK text's twin) | 270 ms | 6.8 MB | 2.8 MB |
| Window read, 20 000 units at offset 100 000 000 of the 500 MB file | **1.9 ms** | 5.2 MB | 1.3 MB |
| Pure-Dart streaming index, same 500 MB file | 11 570 ms | 267 MB | 20.2 MB |
| `File.readAsString()`, same 500 MB file | 2 797 ms | **1 060 MB** | 817 MB |
| The engine through the bridge (release DLL, Dart process) | 925 ms | 270 MB | 24.4 MB |
| …through the bridge (debug DLL, what `flutter run` loads) | 9 995 ms | | 10.8× slower |

Targets from `docs/user-data-contract.md` D4/D10: a 500 MB pass under ~1 s and
peak RSS under ~50 MB. **Both hold for the engine itself** (609 ms, 5.7 MB); the
Dart-side rows show why the work left Dart: the pure-Dart pass is 19× slower and
the decode the reader does today costs 817 MB more than the file it reads. The
`File.readAsString()` row reproduces the contract's existing measurement (2.9 s,
≈ 1 GB) on this machine.

**The encoding argument is now a measured row, not a claim.** `dart:convert` has
no GBK decoder: `File.readAsStringSync()` on the 20 MB GBK file fails with
`FileSystemException: Failed to decode data using encoding 'utf-8'`, and decoding
it with `allowMalformed` produces **13 085 856 replacement characters**. The
engine indexes the same file in 384 ms and a window read returns its text.

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
- **Conversion timing in the app.** The measured conversion row is ~90 ns per
  code unit (1 M units per direction in 178 ms), i.e. sub-millisecond for the few
  thousand units of a chapter, but no reader has converted a chapter yet.
