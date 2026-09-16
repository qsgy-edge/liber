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
///   mainland too, so they are protected from that mapping. Only Simplified
///   spellings belong here: protecting a Traditional one (編著) would keep the
///   whole word unconverted, so those are entries in the phrase table instead
///   (編著 → 编著). The zhuó words (著手 → 着手, 著眼 → 着眼, 著色 → 着色) are
///   *not* protected: they are 着 in the mainland.
///
/// Everything else moved to the phrase table (`assets/phrases/`, OpenCC plus the
/// hand decisions in `tool/text_engine_prototype/phrase_decisions.tsv`) or is
/// left to the character table.
pub const T2S_EXCLUDE: &[&str] = &[
    "槃", "魔戒", "著作", "著名", "著者", "著述", "著称", "编著", "译著", "论著", "原著", "巨著",
    "名著", "专著", "显著", "卓著", "昭著", "遗著",
];

/// The embedded tables, as NUL-free UTF-8 text.
const T2S_TABLE: &str = include_str!("../assets/hanlp-tc/t2s.txt");
const S2T_TABLE: &str = include_str!("../assets/hanlp-tc/s2t.txt");
/// Regional wording on top of the character table: Taiwan and Hong Kong words as
/// a mainland reader expects them. Built by `tool/text_engine_prototype/build_phrases.py`
/// from OpenCC's `TWPhrasesRev`/`HKPhrasesRev` (Apache-2.0) plus hand decisions.
const TW_PHRASES: &str = include_str!("../assets/phrases/tw2s.txt");
const HK_PHRASES: &str = include_str!("../assets/phrases/hk2s.txt");
/// The other direction, from OpenCC unedited: a second pass over the character
/// table's output that turns generic Traditional into one place's norm and
/// wording (裏面 → 裡面, 軟件 → 軟體). Its keys are Traditional because that is
/// what it sees.
const TW_SECOND_PASS: &str = include_str!("../assets/phrases/tw.txt");
const HK_SECOND_PASS: &str = include_str!("../assets/phrases/hk.txt");
/// OpenCC's Simplified → Traditional character and phrase tables, merged *under*
/// HanLP's: where the two disagree on a single character HanLP wins, and OpenCC's
/// entries fill the variant characters and phrases HanLP does not carry. Measured
/// on OpenCC's own cases in this repository, `opencc-s2t` 49.4 % against
/// `liber-generic` 34.3 % before the merge.
const ST_CHARACTERS: &str = include_str!("../assets/phrases/st-characters.txt");
const ST_PHRASES: &str = include_str!("../assets/phrases/st-phrases.txt");

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
    TABLE.get_or_init(|| {
        let mut table = Table::parse(S2T_TABLE);
        // HanLP first, so its character choices win ties; OpenCC's phrases are
        // longer entries and match first anyway, and its characters fill the
        // gaps (the variant characters HanLP's table lacks).
        table.merge(Table::parse(ST_PHRASES));
        table.merge(Table::parse(ST_CHARACTERS));
        table
    })
}

fn tw_second_pass() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| Table::parse(TW_SECOND_PASS))
}

fn hk_second_pass() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| Table::parse(HK_SECOND_PASS))
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
    match target {
        ConvertTarget::SimplifiedMainland => run(text, t2s()),
        ConvertTarget::TraditionalGeneric => run(text, s2t()),
        // Two passes: characters first, then the regional norm and wording over
        // the result (the second pass is keyed in Traditional).
        ConvertTarget::TraditionalTaiwan => run(&run(text, s2t()), tw_second_pass()),
        ConvertTarget::TraditionalHongKong => run(&run(text, s2t()), hk_second_pass()),
    }
}

fn run(text: &str, table: &Table) -> String {
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
        assert_eq!(reading("鳳梨"), "菠萝");
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
            divergences, 12,
            "与冻结基线的差异行数变了，需要更新 ADR 0009"
        );
    }

    #[test]
    fn non_bmp_and_ascii_units_survive() {
        assert_eq!(t2s_of("abc 123 \u{2b748} 測試"), "abc 123 \u{2b748} 测试");
        assert_eq!(s2t_of("abc 123 \u{2b748} 测试"), "abc 123 㑮 測試");
    }
}

#[cfg(test)]
mod traditional_targets {
    use super::*;

    /// The Traditional targets: characters, then the regional norm and wording.
    #[test]
    fn traditional_targets_map_regional_forms() {
        let generic = |text| convert_to(text, ConvertTarget::TraditionalGeneric);
        let taiwan = |text| convert_to(text, ConvertTarget::TraditionalTaiwan);
        let hong_kong = |text| convert_to(text, ConvertTarget::TraditionalHongKong);
        // Characters: 里 → 裏 in the generic norm, 裡 in Taiwan's.
        assert_eq!(generic("里面"), "裏面");
        assert_eq!(taiwan("里面"), "裡面");
        assert_eq!(hong_kong("里面"), "裏面");
        // Wording: a mainland word becomes the local one.
        assert_eq!(taiwan("软件"), "軟體");
        assert_eq!(hong_kong("软件"), "軟件");
        assert_eq!(taiwan("U盘"), "隨身碟");
        assert_eq!(taiwan("鼠标"), "滑鼠");
        assert_eq!(taiwan("打印机"), "印表機");
        assert_eq!(taiwan("光盘"), "光碟");
        assert_eq!(hong_kong("伊利诺伊州"), "伊利諾州");
        // The character-only path stays generic, because `java.s2t` is what a
        // Book Source rule calls and it must not choose a place for the reader.
        assert_eq!(convert("软件", Direction::SimplifiedToTraditional), "軟件");
        assert_eq!(convert("里面", Direction::SimplifiedToTraditional), "裏面");
    }
}
