# Where `t2s.txt` and `s2t.txt` come from

Both files are verbatim copies from HanLP's `1.x` branch,
`data/dictionary/tc/`, fetched 2026-09-16:

| File | Branch tip when fetched | Last commit that touched it | sha256 |
|---|---|---|---|
| `t2s.txt` | `dadd5c76a53eb05cc84720628b89e4a334d5d753` | `f7c928c0467624b8f827ef2f5941fc5c3622ade3` (2019-06-28, "无损转换OpenCC词典，结果一致") | `95016946e5fd1085a0a1cbe11e63a4a4e35f392ed7ca21a3d3a30ccc828f1fbf` |
| `s2t.txt` | as above | `f7c928c0…` | `17eea94e87660aafbc3373e3f57f244cb5e197a9fac2a0096bae4721a8ce5ee4` |

- **Licence:** HanLP is Apache-2.0 (`hankcs/HanLP`, `LICENSE`), and the commit
  that last wrote these files says what they are made of: a lossless text
  conversion of OpenCC's dictionaries (Apache-2.0), which Hankcs published as
  `hankcs/OpenCC-to-HanLP`. Nothing in these two files comes from anywhere the
  repository cannot license.
- **Why these and not OpenCC's own files:** `docs/adr/0010-convert-chinese-with-hanlp-tables.md`
  measures both against the frozen reader. HanLP's tables sit three to thirty
  times closer to it, they are readable text in this repository rather than data
  compiled into a dependency, and they are the same upstream family the frozen
  reader's own table started from.
- **What is *not* here:** `t2tw.txt` and `t2hk.txt` from the same directory. The
  frozen reader's two conversion settings are Traditional↔Simplified only
  (`ContentProcessor` and `BookChapter` switch on 1 and 2), so nothing needs them.
- **Unmodified.** The exclude list Legado applies on top is behavioural data and
  lives in `src/convert.rs` (`T2S_EXCLUDE`), not in these files.
