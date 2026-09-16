# Chinese conversion uses HanLP's tables plus Legado's exclude list

**Status:** accepted (2026-09-16)

**The tables are HanLP 1.x's, and the exclude list is Legado's.** `t2s` and `s2t`
are computed by `packages/fjs/liber_text` from `data/dictionary/tc/t2s.txt` and
`s2t.txt` of HanLP's `1.x` branch (Apache-2.0; the two files are text
conversions of OpenCC's dictionaries, HanLP commit `f7c928c0`, "无损转换OpenCC
词典"), with the 38 words of Legado's `io.legado.app.utils.ChineseUtils.fixT2sDict`
held verbatim in the `t2s` direction. The matcher is the frozen library's:
longest match at each position over a trie of longer entries, one character
through a character map otherwise, an excluded word either leaving that map or
entering the trie as its own value, and everything counted in UTF-16 code units,
which is what a Java `char[]` and a Dart string both are.

**The choice was measured, not argued.** The ticket asked for a difference rate
over a real chapter corpus against the frozen reader (quick-transfer-core 0.2.16
plus Legado's exclude list). `tool/text_engine_prototype/` holds the harnesses,
the reports and the corpus provenance; the share of UTF-16 code units that differ
from the frozen reader, with the line share after it where the corpus has lines:

| Candidate | novels `t2s` | modern-TW `t2s` | modern-CN `t2s` | novels `s2t` | modern-TW `s2t` | modern-CN `s2t` |
|---|---|---|---|---|---|---|
| **HanLP + exclude (chosen)** | **0.210 %** | **0.798 %** | **0.055 %** | **0.078 %** | **0.023 %** | **0.021 %** |
| OpenCC `t2s` + exclude | 2.466 % | 1.399 % | 0.111 % | 0.856 % | 0.037 % | 0.589 % |
| OpenCC `tw2sp` + exclude | 2.722 % | 1.085 % | 0.174 % | — | — | — |

The corpora are 三國演義 and 紅樓夢 (890 k units of Traditional prose, public
domain, revision-pinned) and 45 zh.wikipedia articles rendered `variant=zh-tw` and
`variant=zh-cn` (984 k units each, the modern prose that carries Taiwan
vocabulary and mainland Simplified); the numbers are in
`tool/text_engine_prototype/evidence/conversion-*.json`. The control rows — the
frozen library's own tables re-run through the same matcher — reproduce the frozen
output **exactly** on all 2.85 M code units, so a row's divergences belong to its
tables, not to the matcher.

**What the divergences are decides it as much as their size.** The frozen reader's
`t2s` table is a merge: HanLP's own table plus `luhuiguo/chinese-utils`' phrase
lists plus further edits, 5 512 entries more than HanLP's, inside a library whose
repository declares no licence. This product therefore diverges mostly by
*under-conversion*: a Taiwan word keeps its characters and its word (檔案 → 档案,
記憶體 → 记忆体) where the frozen reader writes 文件 and 内存, and a few characters
it has since learned stay Traditional (『』, 姪). Twice the direction is the other
way: 乾 converts here and is deliberately unmapped there, and the excluded words
stay verbatim exactly because Legado says so. OpenCC's divergences are of another
kind: it leaves the frozen conversation's punctuation alone (`「」` stays `「」`
where the frozen reader writes `“”`, and `tw2sp` turns `“”` *into* `「」`), and it
normalises variants (`爲` → `為`, `吃` → `喫`, `擡` → `抬`) — behaviour a reader
would notice as a change of text rather than a leftover.

## Considered options

- **B — OpenCC's tables (ferrous-opencc, Apache-2.0, pure Rust).** Measured 3 to
  30 times further from the frozen reader, and its data is compiled into a
  third-party crate (with `rkyv`/`rend`/`rancor` in the build) rather than
  readable text in this repository, so a behaviour change arrives as a crate
  upgrade. Rejected on both counts. `opencc-fmmseg` is a second OpenCC
  reimplementation and shares the second problem; its custom-dictionary API was
  the one thing that would have made an OpenCC-plus-exclude-list option possible
  without writing the matcher, and the measurement shows the result would still
  have been OpenCC's punctuation and variant behaviour.
- **C — ship the frozen library's own tables.** Rejected: the table is the
  baseline's behaviour exactly, but it lives inside an unlicensed jar, and the
  repository's whole provenance discipline is that it does not redistribute what
  it cannot license.
- **`zhconv`'s default feature.** Rejected: its tables are MediaWiki's GPLv2.0+
  data. Its `opencc` feature is the Apache-2.0 alternative and is otherwise the
  same data as B.
- **`flutter_opencc_plus` (the real OpenCC 1.4.1 behind a Dart FFI wrapper).**
  Rejected: a prebuilt third-party binary downloaded by a Dart build hook, for
  five platforms, to get output the C++ reference does not define any more
  precisely than the tables do.
- **A Dart-side matcher over the same tables.** Rejected: Dart's `RegExp` cannot
  express the default chapter rules' lookbehind, and the conversion is needed at
  the JavaScript host surface anyway, where a rule calls `java.t2s` synchronously
  inside its own script.
- **Claiming parity with the frozen reader.** Rejected: the measurement says
  otherwise. The divergence is recorded here, in the capability matrix, and in
  the crate's own fixtures, where every row the two disagree on is marked.

## Consequences

The reader's chapter and TOC conversion and the Book Source host surface's
`java.t2s`/`java.s2t` are now the same implementation, so a source and the reader
cannot disagree about a character. `packages/fjs/liber_text` carries the two
tables as committed text (1.1 MB, parsed once per process) and its tests pin:
the exclude list word by word, the fixture rows the baseline oracle produced, and
that the divergence count the fixture records (8 of 74 rows) matches this ADR. A
future slice could close part of the residual gap by adding more licence-clean
upstream tables (chinese-utils' phrase lists are Apache-2.0), additively and
without touching the matcher; nothing here claims the gap is closed.

See `docs/compatibility/book-source-capability-matrix.md` for the `t2s`/`s2t`
row this changes, and `tool/text_engine_prototype/` for the harnesses, the raw
reports and the re-run steps. Provenance: ticket #19, with the frozen-oracle
harness kept beside the other retired ones in `liber-archive`.
