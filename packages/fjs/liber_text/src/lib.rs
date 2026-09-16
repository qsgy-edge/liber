//! Liber's Rust text engine: encoding detection, one-pass indexing, window
//! decoding and Chinese conversion for local files.
//!
//! The product's contract (`docs/user-data-contract.md`, D4 and D10) fixes what
//! this crate owns: a local TXT is decoded once, indexed in one streaming pass
//! into sparse byte ↔ code-unit anchors at line starts plus chapter boundaries,
//! and afterwards read back as bounded windows — never as a whole document. The
//! same conversion implementation serves the reader's chapter and TOC paths and
//! the Book Source host surface's `java.t2s`/`java.s2t`.
//!
//! # Conversion tables
//!
//! `assets/hanlp-tc/` holds HanLP 1.x's `data/dictionary/tc/t2s.txt` and
//! `s2t.txt` (Apache-2.0), which are themselves text conversions of OpenCC's
//! dictionaries (HanLP commit `f7c928c0`, "无损转换OpenCC词典"). On top of them
//! this crate applies the exclude list Legado loads for `t2s`
//! (`io.legado.app.utils.ChineseUtils.fixT2sDict`), so the 38 words that the
//! frozen reader keeps verbatim stay verbatim here too.
//!
//! The longest-match matcher reproduces the frozen library's semantics exactly,
//! UTF-16 code units included: a one-unit entry goes to the character map, a
//! longer entry to the trie, the trie's longest key bounds a match, an excluded
//! word either leaves the character map or enters the trie as its own value. It
//! was validated by running the frozen library's own tables through it and
//! comparing 2.2 M code units of real chapters byte for byte
//! (`tool/text_engine_prototype/`).
//!
//! # Encodings
//!
//! `encoding_rs` (the Encoding Standard implementation Firefox uses) decodes, so
//! GBK, GB18030 and Big5 work on every platform. Detection is BOM first, then a
//! UTF-8 validity check on the sample, then `chardetng` — the same Firefox
//! detector, which exists for exactly this GBK/Big5 case. `dart:convert` can do
//! none of this, which is why the decode lives on this side of the bridge.

mod convert;
mod scan;

pub use convert::{Direction, convert};
pub use scan::{
    Anchor, Chapter, Index, IndexOptions, TextError, Window, detect_encoding, index_file,
    read_window,
};
