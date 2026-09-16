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

## Revision (2026-09-16): accuracy, not parity

The decision above was made against one criterion: agreement with the frozen
reader. The product's actual criterion is different — a reader who only reads
Simplified should get *mainland* Simplified, wording included — and measuring
that (an accuracy harness, `tool/text_engine_prototype/`, and the two reference
sets it scores against) showed the parity criterion had been hiding a real gap:
HanLP's character tables leave 硬碟, 滑鼠, 伺服器, 網際網路 and 資訊 in the text,
because those are wording differences, not character differences.

So the tables are now:

1. HanLP 1.x `tc` characters, unchanged (`assets/hanlp-tc/`);
2. **plus** `assets/phrases/tw2s.txt` and `hk2s.txt`: OpenCC's `TWPhrasesRev` /
   `HKPhrasesRev` (Apache-2.0) minus 38 entries the corpus audit disagreed with,
   plus 3 overrides and 79 additions (檔案館 → 档案馆, 存檔 → 存档, 智慧型 →
   智能型, 著 → 着 and so on). The audit, the decisions and the build are all
   re-runnable scripts; see `assets/phrases/README.md`;
3. **minus** an exclude list reduced from Legado's 38 protected words to the ones
   where converting is *wrong* rather than merely different: 槃 (涅槃), 魔戒, and
   the zhù words (著作, 著名, 显著 …) that keep 著 in the mainland.

The result against the Wikipedia reference set (18 658 sentences, `zh-tw` against
its `zh-cn` rendering), per 1 000 code units of output: Traditional characters
left **0.06** (the reference itself leaves 20.5, the previous implementation
0.36), sentence-level exact matches **72.8 %** (was 68.8 %), error positions
**1.01 %** (was 1.71 %), and positions the reference converts but this product
leaves as Traditional **1 969** (was 4 530). OpenCC's own hand-made cases agree on
50.6 % of rows at a 5.6 % error rate (was 40.8 % / 12.2 %).

The Traditional direction was wired the same day and measured against the mirror
image of the same corpus (the 18 653 sentences as `zh-cn` input against their
`zh-tw` rendering): `liber_taiwan` 67.6 % sentence-level exact, OpenCC's own
`s2twp` 61.8 %, `liber_generic` 53.8 %, the frozen reader 53.7 %. Those tables
(`tw.txt`, `hk.txt`: OpenCC's `TWPhrases`+`TWVariants` and `HKPhrases`+`HKVariants`)
are unedited and run as a *second pass*, because OpenCC keys them in Traditional —
its pipeline converts characters first. On OpenCC's own cases the character table
was the weak link (`opencc-s2t` 49.4 % against `liber_generic` 34.3 %, because
HanLP's `s2t` table lacks the variant characters OpenCC's carries), so the
character side now merges OpenCC's `STCharacters`/`STPhrases` under HanLP's: the
Taiwan target reaches 67.8 % on the Wikipedia mirror set and the generic one
56.0 % on OpenCC's cases, above OpenCC's own `s2t`.

Two consequences worth stating plainly. First, the frozen reader's `t2s` is no
longer the reference behaviour: the character-only path (`java.t2s`, which Book
Source rules call) stays as it was, but the reader's conversion deliberately
differs. Second, the remaining disagreements are mostly wording choices where no
standard exists (資訊 → 信息 against the reference's 资讯, 电脑 against 计算机);
the harness reports those separately as *wording variants* and prints both error
rates rather than scoring one community's style as the truth.
