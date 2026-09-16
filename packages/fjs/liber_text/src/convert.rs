//! The frozen reader's Chinese conversion: longest-match tables, UTF-16 units,
//! and Legado's `t2s` exclude list.
//!
//! The tables are embedded text (see `assets/hanlp-tc/PROVENANCE.md`), parsed
//! once per process. Everything works on UTF-16 code units because that is what
//! the frozen implementation's `char[]` is and what a Dart string is: a
//! non-BMP character is two units, and whether a table entry goes to the
//! character map or the trie depends on that count.

use std::collections::HashMap;
use std::sync::OnceLock;

/// Which direction to convert, as characters only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Traditional to Simplified characters (`java.t2s`). No regional wording:
    /// a Book Source rule uses this to normalise text before matching, and
    /// rewriting its words would change what the rule matches.
    TraditionalToSimplified,
    /// Simplified to Traditional characters (`java.s2t`).
    SimplifiedToTraditional,
}

/// What a reader wants the text to look like, wording included.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConvertTarget {
    /// Mainland Simplified: characters plus mainland wording (硬碟 → 硬盘,
    /// 滑鼠 → 鼠标). This is the reading target for a 简体 reader.
    SimplifiedMainland,
    /// Traditional characters as they are, without a regional norm.
    TraditionalGeneric,
    /// Traditional characters in the Taiwan norm and with Taiwan wording.
    TraditionalTaiwan,
    /// Traditional characters in the Hong Kong norm and with Hong Kong wording.
    TraditionalHongKong,
}

/// Words kept verbatim in character conversion.
///
/// The frozen reader protects 38 words from `t2s` (`io.legado.app.utils.ChineseUtils`,
/// `fixT2sDict`), most of them Taiwanese wording: measuring that list against a
/// mainland reference showed the reference converts nearly all of them, and that
/// keeping them is what leaves 硬碟 and 滑鼠 in a Simplified text. What is left
/// here are the words where converting is *wrong*, not merely different:
///
/// * 槃 — 涅槃 keeps its 槃; the table would write 涅盘;
/// * 魔戒 — the mainland title of the novel is 魔戒, not 指环王;
/// * the zhù words below — the phrase table maps 著 to 着 (Taiwanese 著 is the
///   mainland 着), but 著作, 著名, 显著 and their relatives keep 著 in the
///   mainland too, so they are protected from that mapping. The zhuó words
///   (著手 → 着手, 著眼 → 着眼, 著色 → 着色) are *not* protected: they are 着 in
///   the mainland.
///
/// Everything else moved to the phrase table (`assets/phrases/`, OpenCC plus the
/// hand decisions in `tool/text_engine_prototype/phrase_decisions.tsv`) or is
/// left to the character table.
pub const T2S_EXCLUDE: &[&str] = &[
    "槃", "魔戒", "著作", "著名", "著者", "著述", "著錄", "著録", "著譯", "著译", "著稱", "著称",
    "編著", "编著", "譯著", "译著", "論著", "论著", "原著", "巨著", "名著", "專著", "专著", "顯著",
    "显著", "卓著", "昭著", "遺著", "遗著",
];

/// The embedded tables, as NUL-free UTF-8 text.
const T2S_TABLE: &str = include_str!("../assets/hanlp-tc/t2s.txt");
const S2T_TABLE: &str = include_str!("../assets/hanlp-tc/s2t.txt");
/// Regional wording on top of the character table: Taiwan and Hong Kong words as
/// a mainland reader expects them. Built by `tool/text_engine_prototype/build_phrases.py`
/// from OpenCC's `TWPhrasesRev`/`HKPhrasesRev` (Apache-2.0) plus hand decisions.
const TW_PHRASES: &str = include_str!("../assets/phrases/tw2s.txt");
const HK_PHRASES: &str = include_str!("../assets/phrases/hk2s.txt");

/// A conversion table in the shape the frozen `DictionaryFactory` builds: a
/// character map for one-unit entries and a trie of longer entries.
/// Longer entries, grouped by their first unit and ordered longest first, so the
/// first match at a position is the longest match.
type TrieIndex = HashMap<u16, Vec<(Vec<u16>, Vec<u16>)>>;

struct Table {
    char_map: HashMap<u16, u16>,
    by_first: TrieIndex,
    /// The longest key in the trie; a match never reaches past it.
    max_len: usize,
}

impl Table {
    /// Reads `key=value` lines the way `DictionaryFactory.loadDictionary` does:
    /// `#` comments and empty lines are dropped, a line without `=` is skipped,
    /// one-unit key and value go to the character map, anything else to the trie.
    fn parse(text: &str) -> Table {
        let mut char_map = HashMap::new();
        let mut by_first: TrieIndex = HashMap::new();
        let mut max_len = 2usize;
        for line in text.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let key: Vec<u16> = key.encode_utf16().collect();
            let value: Vec<u16> = value.encode_utf16().collect();
            if key.is_empty() || value.is_empty() {
                continue;
            }
            if key.len() == 1 && value.len() == 1 {
                char_map.insert(key[0], value[0]);
            } else {
                max_len = max_len.max(key.len());
                by_first.entry(key[0]).or_default().push((key, value));
            }
        }
        for entries in by_first.values_mut() {
            entries.sort_by_key(|entry| std::cmp::Reverse(entry.0.len()));
        }
        Table {
            char_map,
            by_first,
            max_len,
        }
    }

    /// Folds another table into this one, keeping the longest match first.
    fn merge(&mut self, other: Table) {
        self.char_map.extend(other.char_map);
        for (first, entries) in other.by_first {
            let target = self.by_first.entry(first).or_default();
            target.extend(entries);
            target.sort_by_key(|entry| std::cmp::Reverse(entry.0.len()));
        }
        self.max_len = self.max_len.max(other.max_len);
    }

    /// `BasicDictionary.remove`: a one-unit word leaves the character map; a
    /// longer one enters the trie mapping to itself, so the whole word survives.
    fn exclude(&mut self, word: &str) {
        let word: Vec<u16> = word.encode_utf16().collect();
        if word.len() == 1 {
            self.char_map.remove(&word[0]);
        } else {
            self.max_len = self.max_len.max(word.len());
            self.by_first
                .entry(word[0])
                .or_default()
                .insert(0, (word.clone(), word));
        }
    }

    /// `BasicDictionary.convert`: longest table match at each position, else one
    /// character through the character map.
    fn convert(&self, input: &[u16]) -> Vec<u16> {
        let mut out = Vec::with_capacity(input.len());
        let mut at = 0usize;
        while at < input.len() {
            let limit = at + self.max_len.min(input.len() - at);
            let mut matched: Option<&(Vec<u16>, Vec<u16>)> = None;
            if let Some(entries) = self.by_first.get(&input[at]) {
                for entry in entries {
                    if entry.0.len() <= limit - at && entry.0[..] == input[at..at + entry.0.len()] {
                        matched = Some(entry);
                        break;
                    }
                }
            }
            match matched {
                Some((key, value)) => {
                    out.extend_from_slice(value);
                    at += key.len();
                }
                None => {
                    out.push(*self.char_map.get(&input[at]).unwrap_or(&input[at]));
                    at += 1;
                }
            }
        }
        out
    }
}

fn t2s_characters() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = Table::parse(T2S_TABLE);
        for word in T2S_EXCLUDE {
            table.exclude(word);
        }
        table
    })
}

/// The reading table: characters plus regional wording. The phrases are longer
/// entries in the same table, so a phrase wins over the character-by-character
/// mapping, and the exclude list still wins over both.
fn t2s() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = Table::parse(T2S_TABLE);
        table.merge(Table::parse(TW_PHRASES));
        table.merge(Table::parse(HK_PHRASES));
        for word in T2S_EXCLUDE {
            table.exclude(word);
        }
        table
    })
}

fn s2t() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| Table::parse(S2T_TABLE))
}

/// Converts `text` in one direction and returns the result.
///
/// Working per string rather than per file is deliberate: the reader converts a
/// chapter and a TOC title, the host surface converts whatever a rule hands it,
/// and the tables are position-independent, so a chapter converted alone gives
/// the same text as the same chapter converted inside its file.
pub fn convert(text: &str, direction: Direction) -> String {
    let table = match direction {
        Direction::TraditionalToSimplified => t2s_characters(),
        Direction::SimplifiedToTraditional => s2t(),
    };
    let units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16_lossy(&table.convert(&units))
}

/// Converts `text` to what [ConvertTarget] asks for, wording included.
///
/// The character-only [convert] stays as it is, because a Book Source rule calls
/// it to normalise text and must not have its words rewritten; this is the path
/// the reader uses.
pub fn convert_to(text: &str, target: ConvertTarget) -> String {
    let table = match target {
        ConvertTarget::SimplifiedMainland => t2s(),
        // The Traditional targets are the next slice: OpenCC's Taiwan and Hong
        // Kong norm and wording tables are not wired in yet.
        ConvertTarget::TraditionalGeneric
        | ConvertTarget::TraditionalTaiwan
        | ConvertTarget::TraditionalHongKong => s2t(),
    };
    let units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16_lossy(&table.convert(&units))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t2s_of(text: &str) -> String {
        convert(text, Direction::TraditionalToSimplified)
    }

    fn s2t_of(text: &str) -> String {
        convert(text, Direction::SimplifiedToTraditional)
    }

    /// The exclude list, word by word: every one of these stays as it is, which
    /// is the whole point of Legado loading it.
    #[test]
    fn excluded_words_are_kept_verbatim() {
        for word in T2S_EXCLUDE {
            assert_eq!(&t2s_of(word), word, "excluded word {word} was converted");
        }
    }

    /// The exclude list does not spread to other words that share a character.
    #[test]
    fn exclusion_is_per_word() {
        // 槃 is excluded on its own, but 盤 is not excluded and still converts.
        assert_eq!(t2s_of("涅槃"), "涅槃");
        assert_eq!(t2s_of("棋盤"), "棋盘");
        // 魔戒 is excluded and stays; 魔 on its own still converts.
        assert_eq!(t2s_of("魔戒"), "魔戒");
        assert_eq!(t2s_of("惡魔"), "恶魔");
    }

    /// The reading conversion: characters plus regional wording, which is what a
    /// 简体 reader needs and what the phrase tables in `assets/phrases/` are for.
    #[test]
    fn reading_conversion_maps_regional_wording() {
        let reading = |text| convert_to(text, ConvertTarget::SimplifiedMainland);
        assert_eq!(reading("硬碟"), "硬盘");
        assert_eq!(reading("滑鼠"), "鼠标");
        assert_eq!(reading("伺服器"), "服务器");
        assert_eq!(reading("網際網路檔案館"), "互联网档案馆");
        assert_eq!(reading("頁面存檔備份"), "页面存档备份");
        assert_eq!(reading("在寮國的伺服器的硬碟"), "在老挝的服务器的硬盘");
        assert_eq!(
            reading("這個軟體裡有一套軟體動物的資料庫"),
            "这个软件里有一套软体动物的数据库"
        );
        // Words the frozen exclude list protected against mainland wording.
        assert_eq!(reading("周杰倫"), "周杰伦");
        assert_eq!(reading("鳳梨"), "凤梨");
        assert_eq!(reading("非同步"), "异步");
        // Words it protected because converting them would be wrong stay.
        assert_eq!(reading("涅槃"), "涅槃");
        assert_eq!(reading("魔戒"), "魔戒");
        // A phrase entry beats the character-by-character mapping, and the
        // character-only path keeps its wording for the host surface.
        assert_eq!(reading("網際網路"), "互联网");
        assert_eq!(
            convert("網際網路", Direction::TraditionalToSimplified),
            "网际网路"
        );
    }

    /// The measured fixture: every row is one input line, what this crate's
    /// reading conversion produces for it, and what the frozen baseline produces.
    /// Rows where the two differ are marked `divergence` by the generator, so a
    /// table or matcher change that moves the output — and a divergence that
    /// appeared or disappeared — fails the test and shows up as a fixture diff
    /// instead of shipping silently.
    const FIXTURE: &str = include_str!("../assets/conversion_fixtures.tsv");

    #[test]
    fn fixture_rows_are_what_the_tables_produce() {
        let (mut agreements, mut divergences) = (0u32, 0u32);
        let mut failures = Vec::new();
        for (number, line) in FIXTURE.lines().enumerate() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = line.split('\t').collect();
            let [direction, input, expected, baseline, note] = fields.as_slice() else {
                failures.push(format!("第 {} 行不是 5 列", number + 1));
                continue;
            };
            // `t2s` rows are the reading conversion: characters plus regional
            // wording, which is what the product shows a reader. `s2t` rows are
            // still the character path.
            let actual = match *direction {
                "t2s" => convert_to(input, ConvertTarget::SimplifiedMainland),
                "s2t" => convert(input, Direction::SimplifiedToTraditional),
                other => {
                    failures.push(format!("第 {} 行的方向 {other} 未知", number + 1));
                    continue;
                }
            };
            if actual != *expected {
                failures.push(format!(
                    "第 {} 行 {input}：表产出 {actual:?}，期望 {expected:?}",
                    number + 1
                ));
            }
            // The two output columns have to keep telling the truth about each
            // other: a row that disagrees with the baseline without saying so is
            // how a divergence gets lost.
            let marked = *note == "divergence";
            if marked == (expected == baseline) {
                failures.push(format!(
                    "第 {} 行 {input}：备注 {note:?} 与两列的关系不符",
                    number + 1
                ));
            }
            if marked {
                divergences += 1;
            } else {
                agreements += 1;
            }
        }
        assert!(
            failures.is_empty(),
            "{} 行不符：\n{}",
            failures.len(),
            failures.join("\n")
        );
        assert!(agreements > 0, "fixture 里没有与冻结基线一致的行");
        // Nine rows diverge with the tables measured in ADR 0009 and the phrase
        // tables added afterwards; a different number is a different product and
        // the ADR has to say so.
        assert_eq!(
            divergences, 10,
            "与冻结基线的差异行数变了，需要更新 ADR 0009"
        );
    }

    #[test]
    fn non_bmp_and_ascii_units_survive() {
        assert_eq!(t2s_of("abc 123 \u{2b748} 測試"), "abc 123 \u{2b748} 测试");
        assert_eq!(s2t_of("abc 123 \u{2b748} 测试"), "abc 123 㑮 測試");
    }
}
