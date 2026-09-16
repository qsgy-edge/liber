//! One streaming pass over a local file: detect the encoding, index it, read it
//! back in bounded windows.
//!
//! Everything here is line-oriented because a local TXT's only structure is its
//! lines: chapter rules match lines, the sparse anchors sit at line starts, and
//! progress records a line index. The file is read in chunks and split into lines
//! on its raw bytes, and each line is decoded through one incremental
//! `encoding_rs` decoder fed segment by segment: segments end at newlines, which
//! are complete characters in every encoding the product reads, so byte offsets
//! and code-unit offsets stay exact and a stateful encoding still sees its bytes
//! in order. Nothing holds more than one line plus the anchors.

use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::Path;

use encoding_rs::{Decoder, Encoding, UTF_8, UTF_16BE, UTF_16LE};
/// What went wrong while indexing or reading a file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TextError {
    /// The file could not be read.
    Io(String),
    /// The encoding name is not one the Encoding Standard knows.
    UnknownEncoding(String),
    /// The file starts with a byte order mark for an encoding the engine does
    /// not decode (UTF-32). Byte order marks for UTF-8 and UTF-16 are handled.
    UnsupportedEncoding(String),
    /// A window was requested far from the anchor that was handed in, past the
    /// caller's scan limit; the anchors are stale.
    AnchorTooFar {
        /// Bytes scanned from the anchor before giving up.
        scanned_bytes: u64,
        /// The caller's limit.
        limit: u64,
    },
    /// A window was requested past the end of the file.
    OffsetOutOfRange {
        /// The requested code-unit offset.
        offset: u64,
        /// The file's code-unit length.
        code_unit_length: u64,
    },
}

impl std::fmt::Display for TextError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TextError::Io(message) => write!(formatter, "读取文件失败：{message}"),
            TextError::UnknownEncoding(name) => write!(formatter, "未知编码：{name}"),
            TextError::UnsupportedEncoding(name) => write!(formatter, "不支持的编码：{name}"),
            TextError::AnchorTooFar {
                scanned_bytes,
                limit,
            } => write!(
                formatter,
                "索引锚点已过期：从锚点起已扫描 {scanned_bytes} 字节，超过 {limit} 字节上限"
            ),
            TextError::OffsetOutOfRange {
                offset,
                code_unit_length,
            } => write!(formatter, "偏移 {offset} 超出文件长度 {code_unit_length}"),
        }
    }
}

impl std::error::Error for TextError {}

type Result<T> = std::result::Result<T, TextError>;

fn io_error(error: std::io::Error) -> TextError {
    TextError::Io(error.to_string())
}

/// Bytes read for encoding detection. Large enough for `chardetng` to be
/// confident on a CJK novel, small enough to stay irrelevant next to the pass.
const SAMPLE_BYTES: usize = 64 * 1024;
/// When the sample is pure ASCII the file could still be any legacy encoding
/// further in, so the sample grows until something non-ASCII appears.
const ASCII_SAMPLE_BYTES: usize = 4 * 1024 * 1024;
/// Chunk size for the reading passes.
const CHUNK_BYTES: usize = 256 * 1024;

/// The frozen reader's two enabled default TXT chapter rules
/// (`app/src/main/assets/defaultData/txtTocRule.json`, ids -1 and -2). They are
/// the default here rather than in Dart because Dart's `RegExp` has no
/// lookbehind, so the "目录(去空白)" rule cannot be expressed on the Dart side at
/// all. A caller that stores its own rule list passes `toc_rules`.
pub const DEFAULT_TOC_RULES: &[&str] = &[
    "(?<=[　\\s])(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\\s{0,4}[\\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\\s{0,4}(?:章|节(?!课)|卷|集(?![合和]))).{0,30}$",
    "^[ 　\\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\\s{0,4}[\\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|篇(?!张))).{0,30}$",
];

/// What was detected about a file's text encoding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Detection {
    /// The Encoding Standard name (`UTF-8`, `GBK`, `Big5`, …).
    pub encoding: String,
    /// Whether the encoding came from a byte order mark.
    pub bom: bool,
}

/// A sparse anchor: one line start, in bytes, in code units, and in lines.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Anchor {
    /// Byte offset of the line start in the file.
    pub byte_offset: u64,
    /// UTF-16 code-unit offset of the same position in the decoded text.
    pub code_unit_offset: u64,
    /// Zero-based line index of the same position.
    pub line_index: u64,
}

/// A chapter boundary the TOC rules found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chapter {
    /// The matched text: the title the frozen reader stores (`matcher.group()`,
    /// i.e. without the whitespace a rule's lookbehind excludes).
    pub title: String,
    /// Byte offset of the line start where the chapter begins.
    pub byte_offset: u64,
    /// UTF-16 code-unit offset of the same position.
    pub code_unit_offset: u64,
    /// Zero-based line index of the same position.
    pub line_index: u64,
}

/// How to build the index and read windows back.
#[derive(Debug, Clone)]
pub struct IndexOptions {
    /// One anchor at least every this many bytes, aligned to a line start. The
    /// reader seeks to the nearest anchor and scans forward, so this bounds a
    /// window read's work.
    pub anchor_stride_bytes: u64,
    /// TOC rules, in the order the frozen reader applies them: the first rule
    /// that matches a line makes that line a chapter boundary. Empty means no
    /// chapter detection, and the caller treats the file as one implicit
    /// chapter (D4).
    pub toc_rules: Vec<String>,
    /// The longest anchor-to-target scan a window read may perform before it
    /// reports stale anchors.
    pub max_scan_bytes: u64,
}

impl Default for IndexOptions {
    fn default() -> Self {
        IndexOptions {
            anchor_stride_bytes: 32 * 1024,
            toc_rules: DEFAULT_TOC_RULES
                .iter()
                .map(|rule| (*rule).to_string())
                .collect(),
            max_scan_bytes: 4 * 1024 * 1024,
        }
    }
}

/// The one-pass result: what the file is, how long it is in both units, and the
/// anchors and chapter boundaries the reader stores in `text_index`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Index {
    /// The detected encoding's name.
    pub encoding: String,
    /// The file's size in bytes.
    pub byte_length: u64,
    /// The file's length in UTF-16 code units — the unit progress is stored in.
    pub code_unit_length: u64,
    /// Line starts, sparse by [`IndexOptions::anchor_stride_bytes`]; the first
    /// anchor is always the first line.
    pub anchors: Vec<Anchor>,
    /// Chapter boundaries, empty when no rule matched.
    pub chapters: Vec<Chapter>,
    /// Rules that do not compile. The frozen reader ignores a rule it cannot
    /// compile and opens the book without it, so the pass does too; the caller
    /// can tell the reader about them.
    pub ignored_rules: Vec<String>,
}

/// A bounded read: the text starting at a requested offset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Window {
    /// The decoded text, at most `max_code_units` units long.
    pub text: String,
    /// The code-unit offset the window starts at: the one that was asked for.
    pub code_unit_offset: u64,
    /// The byte offset the window starts at.
    pub byte_offset: u64,
    /// The line the window starts in.
    pub line_index: u64,
    /// Whether the window ends at the end of the file.
    pub at_end: bool,
}

/// A byte order mark for an encoding this engine cannot decode. `encoding_rs`
/// has no UTF-32 decoder at all, and a UTF-32 TXT is far rarer than the wrong
/// answer would be.
fn unsupported_bom(sample: &[u8]) -> Option<&'static str> {
    if sample.starts_with(&[0xFF, 0xFE, 0x00, 0x00]) {
        Some("UTF-32LE")
    } else if sample.starts_with(&[0x00, 0x00, 0xFE, 0xFF]) {
        Some("UTF-32BE")
    } else {
        None
    }
}

/// Reads up to `limit` bytes from the start of `file`.
fn read_sample(file: &mut File, limit: usize) -> Result<Vec<u8>> {
    let mut sample = vec![0u8; limit];
    let mut filled = 0usize;
    while filled < limit {
        let read = file.read(&mut sample[filled..]).map_err(io_error)?;
        if read == 0 {
            break;
        }
        filled += read;
    }
    sample.truncate(filled);
    Ok(sample)
}

/// Detects the file's encoding: byte order mark first, then a UTF-8 validity
/// check on the sample, then `chardetng` — the detector Firefox uses, which is
/// what makes GBK, GB18030 and Big5 separable at all.
///
/// The frozen reader detects per file with ICU and remembers the answer in the
/// book record; this returns the same kind of answer and the caller is the one
/// that remembers it.
pub fn detect_encoding(path: &Path) -> Result<Detection> {
    let mut file = File::open(path).map_err(io_error)?;
    let mut sample = read_sample(&mut file, SAMPLE_BYTES)?;
    if let Some(name) = unsupported_bom(&sample) {
        return Err(TextError::UnsupportedEncoding(name.to_string()));
    }
    if let Some((encoding, _)) = Encoding::for_bom(&sample) {
        return Ok(Detection {
            encoding: encoding.name().to_string(),
            bom: true,
        });
    }
    // A file that is ASCII so far can still turn into GBK later: a novel's first
    // pages are very often a table of contents written in ASCII digits.
    if sample.len() == SAMPLE_BYTES && sample.iter().all(u8::is_ascii) {
        file.seek(SeekFrom::Start(0)).map_err(io_error)?;
        sample = read_sample(&mut file, ASCII_SAMPLE_BYTES)?;
    }
    if sample_is_utf8(&sample) {
        return Ok(Detection {
            encoding: UTF_8.name().to_string(),
            bom: false,
        });
    }
    // UTF-8 is not allowed as a guess: the sample was already tested for UTF-8
    // validity, and a legacy byte sequence that happens to be valid UTF-8 in
    // the sample is exactly the case that check rejects.
    let mut detector = chardetng::EncodingDetector::new(chardetng::Iso2022JpDetection::Allow);
    detector.feed(&sample, true);
    let encoding = detector.guess(None, chardetng::Utf8Detection::Deny);
    Ok(Detection {
        encoding: encoding.name().to_string(),
        bom: false,
    })
}

/// Whether a sample is UTF-8.
///
/// A sample cut in the middle of a character is still UTF-8: the read stops at a
/// byte count, not at a character boundary, and a 500 MB file whose first
/// 64 KiB happen to end inside a three-byte character must not fall through to
/// a legacy-encoding guess.
fn sample_is_utf8(sample: &[u8]) -> bool {
    match std::str::from_utf8(sample) {
        Ok(_) => true,
        Err(error) => error.error_len().is_none() && error.valid_up_to() + 3 >= sample.len(),
    }
}

/// Resolves an Encoding Standard name, as stored by the caller.
pub fn resolve_encoding(name: &str) -> Result<&'static Encoding> {
    Encoding::for_label(name.as_bytes()).ok_or_else(|| TextError::UnknownEncoding(name.to_string()))
}

/// How the raw bytes are split into lines: UTF-16 newlines are two bytes wide
/// and byte-order dependent, everything else the engine decodes is
/// ASCII-compatible and splits on a single `\n`.
fn newline_pattern(encoding: &'static Encoding) -> &'static [u8] {
    if encoding == UTF_16LE {
        b"\n\0"
    } else if encoding == UTF_16BE {
        b"\0\n"
    } else {
        b"\n"
    }
}

/// One line: where it starts, how long it is in bytes, and its text as UTF-16
/// code units — the unit the reader's offsets, the progress record and Dart
/// strings all use.
///
/// The units are borrowed from the reader's reusable buffer, so a line costs no
/// allocation. The index pass needs them for chapter rules only, and window
/// reads materialise a `String` for the lines they actually return.
struct Line<'a> {
    byte_offset: u64,
    byte_length: u64,
    units: &'a [u16],
}

/// The number of UTF-16 code units in a line.
fn code_units(units: &[u16]) -> u64 {
    units.len() as u64
}

/// Reads a file line by line through one incremental decoder.
///
/// The buffer keeps the bytes that are not consumed yet behind `start`; a line
/// is taken by moving that cursor, and refills compact the remainder and read a
/// new chunk. Draining the front of the buffer per line instead would move the
/// whole tail per line and cost the pass a factor of the line count.
struct LineReader {
    reader: BufReader<File>,
    decoder: Decoder,
    pattern: &'static [u8],
    buffer: Vec<u8>,
    /// The first byte in `buffer` that no line has consumed yet.
    start: usize,
    /// How far the search for a newline has already looked, in `buffer`
    /// coordinates.
    scanned: usize,
    eof: bool,
    position: u64,
    /// The decoded line, reused between lines.
    units: Vec<u16>,
    /// Space the decoder writes into before `units` is trimmed to what it wrote.
    scratch: Vec<u16>,
}

impl LineReader {
    /// Starts reading at `byte_offset`; the caller has already skipped any byte
    /// order mark, so offsets stay file offsets.
    fn new(file: File, encoding: &'static Encoding, byte_offset: u64) -> Result<LineReader> {
        let mut reader = LineReader {
            reader: BufReader::with_capacity(CHUNK_BYTES, file),
            decoder: encoding.new_decoder_without_bom_handling(),
            pattern: newline_pattern(encoding),
            buffer: Vec::new(),
            start: 0,
            scanned: 0,
            eof: false,
            position: byte_offset,
            units: Vec::new(),
            scratch: Vec::new(),
        };
        if byte_offset > 0 {
            reader
                .reader
                .seek(SeekFrom::Start(byte_offset))
                .map_err(io_error)?;
        }
        reader.refill()?;
        Ok(reader)
    }

    /// Reads one more chunk behind the unconsumed bytes, dropping the consumed
    /// prefix first so the buffer does not grow with the file.
    fn refill(&mut self) -> Result<()> {
        if self.eof {
            return Ok(());
        }
        if self.start > 0 {
            self.buffer.copy_within(self.start.., 0);
            self.buffer.truncate(self.buffer.len() - self.start);
            self.scanned = self.scanned.saturating_sub(self.start);
            self.start = 0;
        }
        let from = self.buffer.len();
        self.buffer.resize(from + CHUNK_BYTES, 0);
        let read = loop {
            match self.reader.read(&mut self.buffer[from..]) {
                Ok(read) => break read,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(io_error(error)),
            }
        };
        self.buffer.truncate(from + read);
        if read == 0 {
            self.eof = true;
        }
        Ok(())
    }

    /// The end offset of the next segment and whether it is the file's last one
    /// (an unterminated line at the end of the file).
    fn next_segment(&mut self) -> Result<Option<(usize, bool)>> {
        loop {
            // Never look behind the first unconsumed byte: a scan that returned
            // early on a line's newline leaves `scanned` behind `start`.
            let from = self.start.max(self.scanned);
            if let Some(found) = find_newline(&self.buffer, from, self.pattern) {
                return Ok(Some((found, false)));
            }
            self.scanned = self.buffer.len();
            if self.eof {
                return Ok(if self.buffer.len() == self.start {
                    None
                } else {
                    Some((self.buffer.len(), true))
                });
            }
            self.refill()?;
        }
    }

    /// The next line, or `None` at the end of the file.
    fn next_line(&mut self) -> Result<Option<Line<'_>>> {
        let Some((end, last)) = self.next_segment()? else {
            return Ok(None);
        };
        // The decoder consumes the segment exactly: it ends on a character
        // boundary, so nothing is carried over and the byte offsets stay exact.
        let segment = &self.buffer[self.start..end];
        // One input byte can produce at most one UTF-16 unit in every encoding
        // this engine reads, so this capacity always suffices. The scratch buffer
        // only ever grows to the longest line the file has, so a book with
        // paragraphs of a kilobyte never pays for a buffer it does not need.
        let needed = segment.len() + 8;
        if self.scratch.len() < needed {
            self.scratch.resize(needed, 0);
        }
        let (result, read, written, _) =
            self.decoder
                .decode_to_utf16(segment, &mut self.scratch[..needed], last);
        if read < segment.len() || result == encoding_rs::CoderResult::OutputFull {
            return Err(TextError::Io(format!(
                "解码器在第 {} 字节只读取了 {read} / {} 字节",
                self.position,
                segment.len()
            )));
        }
        self.units.clear();
        self.units.extend_from_slice(&self.scratch[..written]);
        let line = Line {
            byte_offset: self.position,
            byte_length: (end - self.start) as u64,
            units: &self.units,
        };
        self.start = end;
        self.position += line.byte_length;
        Ok(Some(line))
    }
}

/// The end offset of the first newline at or after `from`, or `None`.
///
/// A one-byte newline is found eight bytes at a time with the usual
/// has-a-zero-byte trick, because this scan reads every byte of the file and a
/// byte-at-a-time comparison costs more than the decode it feeds. A two-byte
/// newline (UTF-16) is found unit by unit, which is what those files are rare
/// enough to afford.
fn find_newline(buffer: &[u8], from: usize, pattern: &'static [u8]) -> Option<usize> {
    if pattern.len() == 1 {
        const LO: u64 = 0x0101_0101_0101_0101;
        const HI: u64 = 0x8080_8080_8080_8080;
        let byte = u64::from(pattern[0]) * LO;
        let mut at = from;
        while at + 8 <= buffer.len() {
            let word = u64::from_ne_bytes(buffer[at..at + 8].try_into().expect("8 字节"));
            let matches = word ^ byte;
            if (matches.wrapping_sub(LO) & !matches & HI) != 0 {
                // At least one byte matched: find which one.
                for offset in 0..8 {
                    if buffer[at + offset] == pattern[0] {
                        return Some(at + offset + 1);
                    }
                }
            }
            at += 8;
        }
        while at < buffer.len() {
            if buffer[at] == pattern[0] {
                return Some(at + 1);
            }
            at += 1;
        }
        return None;
    }
    let mut at = from - (from % pattern.len());
    while at + pattern.len() <= buffer.len() {
        if &buffer[at..at + pattern.len()] == pattern {
            return Some(at + pattern.len());
        }
        at += pattern.len();
    }
    None
}

/// The line without its terminator, for rule matching.
fn without_terminator(units: &[u16]) -> &[u16] {
    let mut end = units.len();
    while end > 0 && (units[end - 1] == u16::from(b'\n') || units[end - 1] == u16::from(b'\r')) {
        end -= 1;
    }
    &units[..end]
}

/// Whether a line could match one of the crate's own default rules.
///
/// Every alternative in both default rules begins with one of these characters
/// (see [`DEFAULT_TOC_RULES`]), so a line without any of them cannot match. This
/// is what keeps the backtracking regex engine off the paragraphs that make up
/// almost every line of a book: matching every line of a 500 MB text with those
/// rules costs about seven seconds against the half second the pre-filtered
/// ones do. A caller that supplies its own rules gets every line matched,
/// because nothing can be assumed about a rule this crate did not write.
fn could_match_default_rules(units: &[u16]) -> bool {
    /// The high byte of each trigger character: 序 U+5E8F, 楔 U+6954, 正 U+6B63,
    /// 终 U+7EC8, 后 U+540E, 尾 U+5C3E, 番 U+756A, 第 U+7B2C. A unit whose high
    /// byte is not one of them cannot be a trigger, and the table is small enough
    /// to stay in L1 while the scan runs over the whole book.
    const TRIGGER_HIGH: [bool; 256] = {
        let mut table = [false; 256];
        table[0x54] = true;
        table[0x5C] = true;
        table[0x5E] = true;
        table[0x69] = true;
        table[0x6B] = true;
        table[0x75] = true;
        table[0x7B] = true;
        table[0x7E] = true;
        table
    };
    units.iter().any(|unit| {
        TRIGGER_HIGH[usize::from(unit >> 8)]
            && matches!(
                *unit,
                0x5E8F | 0x6954 | 0x6B63 | 0x7EC8 | 0x540E | 0x5C3E | 0x756A | 0x7B2C
            )
    })
}

/// The chapter title a line carries, if any: the matched text, as the frozen
/// reader's `matcher.group()` returns it.
fn match_rule(rules: &[fancy_regex::Regex], line: &[u16]) -> Option<String> {
    if rules.is_empty() {
        return None;
    }
    let text = String::from_utf16_lossy(line);
    for rule in rules {
        match rule.find(&text) {
            Ok(Some(found)) => return Some(found.as_str().to_string()),
            Ok(None) => continue,
            // A match error means a backtracking limit, not a match.
            Err(_) => continue,
        }
    }
    None
}

/// Builds the index in one pass: anchors at line starts and chapter boundaries.
///
/// The whole file is read once. Nothing is retained except the anchors (about
/// one per [`IndexOptions::anchor_stride_bytes`]) and the chapter boundaries, so
/// the pass costs the file's bytes in I/O and nothing proportional to the book
/// in memory.
pub fn index_file(path: &Path, options: &IndexOptions) -> Result<Index> {
    let detection = detect_encoding(path)?;
    let encoding = resolve_encoding(&detection.encoding)?;
    let mut file = File::open(path).map_err(io_error)?;
    let mut skip = 0u64;
    if detection.bom {
        let bom = read_sample(&mut file, 4)?;
        skip = Encoding::for_bom(&bom)
            .map(|(_, length)| length as u64)
            .unwrap_or(0);
        file.seek(SeekFrom::Start(skip)).map_err(io_error)?;
    }
    let mut reader = LineReader::new(file, encoding, skip)?;
    let (rules, ignored_rules) = compile_rules(&options.toc_rules);
    // A caller that passes exactly the crate's defaults gets the cheap
    // pre-filter; a caller with its own rules gets every line matched.
    let prefilter = options.toc_rules
        == DEFAULT_TOC_RULES
            .iter()
            .map(|rule| (*rule).to_string())
            .collect::<Vec<String>>();
    let mut anchors = vec![Anchor {
        byte_offset: skip,
        code_unit_offset: 0,
        line_index: 0,
    }];
    let mut chapters = Vec::new();
    let mut byte_offset = skip;
    let mut code_unit_offset = 0u64;
    let mut line_index = 0u64;
    while let Some(line) = reader.next_line()? {
        if byte_offset - anchors.last().expect("锚点数组以首行开始").byte_offset
            >= options.anchor_stride_bytes
        {
            anchors.push(Anchor {
                byte_offset,
                code_unit_offset,
                line_index,
            });
        }
        let rule_line = without_terminator(line.units);
        if (!prefilter || could_match_default_rules(rule_line))
            && let Some(title) = match_rule(&rules, rule_line)
        {
            chapters.push(Chapter {
                title,
                byte_offset,
                code_unit_offset,
                line_index,
            });
        }
        byte_offset += line.byte_length;
        code_unit_offset += code_units(line.units);
        line_index += 1;
    }
    Ok(Index {
        encoding: detection.encoding,
        byte_length: byte_offset,
        code_unit_length: code_unit_offset,
        anchors,
        chapters,
        ignored_rules,
    })
}

/// Reads a window of at most `max_code_units` starting exactly at
/// `code_unit_offset`.
///
/// `anchor` is the nearest anchor the caller has stored (a `text_index` row):
/// the read seeks there and scans forward, so the work is bounded by the gap
/// between anchors rather than by the offset's distance from the file's start.
/// `None` means "start at the beginning of the file", which is correct but only
/// cheap near the start: past `max_scan_bytes` the call fails with
/// [`TextError::AnchorTooFar`] instead of quietly reading the whole book.
pub fn read_window(
    path: &Path,
    encoding_name: &str,
    anchor: Option<Anchor>,
    code_unit_offset: u64,
    max_code_units: usize,
    max_scan_bytes: u64,
) -> Result<Window> {
    let encoding = resolve_encoding(encoding_name)?;
    let mut file = File::open(path).map_err(io_error)?;
    let skip = if anchor.is_some() {
        0
    } else {
        let bom = read_sample(&mut file, 4)?;
        Encoding::for_bom(&bom)
            .map(|(_, length)| length as u64)
            .unwrap_or(0)
    };
    let start = anchor.unwrap_or(Anchor {
        byte_offset: skip,
        code_unit_offset: 0,
        line_index: 0,
    });
    if code_unit_offset < start.code_unit_offset {
        return Err(TextError::OffsetOutOfRange {
            offset: code_unit_offset,
            code_unit_length: start.code_unit_offset,
        });
    }
    let mut reader = LineReader::new(file, encoding, start.byte_offset)?;
    let mut position = start.code_unit_offset;
    let mut line_index = start.line_index;
    let mut window: Vec<u16> = Vec::new();
    let mut window_start = None;
    let mut scanned = 0u64;
    let mut at_end = false;
    while let Some(line) = reader.next_line()? {
        scanned += line.byte_length;
        if window_start.is_none() {
            // Not at the target yet: skip whole lines until one contains it.
            if position + code_units(line.units) <= code_unit_offset {
                position += code_units(line.units);
                line_index += 1;
                if scanned > max_scan_bytes {
                    return Err(TextError::AnchorTooFar {
                        scanned_bytes: scanned,
                        limit: max_scan_bytes,
                    });
                }
                continue;
            }
            window_start = Some(Anchor {
                byte_offset: line.byte_offset,
                code_unit_offset,
                line_index,
            });
            window.extend_from_slice(&line.units[(code_unit_offset - position) as usize..]);
        } else {
            window.extend_from_slice(line.units);
        }
        if window.len() >= max_code_units {
            window.truncate(max_code_units);
            break;
        }
    }
    if window_start.is_some() && window.len() < max_code_units {
        at_end = true;
    }
    let Some(start) = window_start else {
        return Err(TextError::OffsetOutOfRange {
            offset: code_unit_offset,
            code_unit_length: position,
        });
    };
    Ok(Window {
        text: String::from_utf16_lossy(&window),
        code_unit_offset: start.code_unit_offset,
        byte_offset: start.byte_offset,
        line_index: start.line_index,
        at_end,
    })
}

/// Compiles the TOC rules, dropping the ones that do not compile: the frozen
/// reader ignores a rule it cannot compile (`toPattern` returns null on a
/// `PatternSyntaxException`) and opens the book without it.
fn compile_rules(rules: &[String]) -> (Vec<fancy_regex::Regex>, Vec<String>) {
    let mut compiled = Vec::with_capacity(rules.len());
    let mut ignored = Vec::new();
    for rule in rules {
        match fancy_regex::Regex::new(rule) {
            Ok(regex) => compiled.push(regex),
            Err(_) => ignored.push(rule.clone()),
        }
    }
    (compiled, ignored)
}

/// The frozen reader applies each rule with `Matcher.find()` on the decoded
/// block; the default rules are whole-line patterns, so a line is a chapter
/// boundary when a rule matches inside it and the matched text is the title.
#[cfg(test)]
fn match_rule_text(rules: &[fancy_regex::Regex], line: &str) -> Option<String> {
    match_rule(rules, &line.encode_utf16().collect::<Vec<u16>>())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn units(text: &str) -> Vec<u16> {
        text.encode_utf16().collect()
    }

    fn lossy(units: &[u16]) -> String {
        String::from_utf16_lossy(units)
    }

    #[test]
    fn terminators_are_stripped_for_matching() {
        assert_eq!(
            lossy(without_terminator(&units("第一章 起点\r\n"))),
            "第一章 起点"
        );
        assert_eq!(lossy(without_terminator(&units("第二章\n"))), "第二章");
        assert_eq!(lossy(without_terminator(&units("正文"))), "正文");
        assert_eq!(without_terminator(&[]), &[] as &[u16]);
    }

    /// The pre-filter is conservative: every line the default rules match must
    /// pass it, or a chapter would vanish from the index.
    #[test]
    fn the_default_rule_prefilter_keeps_every_matching_line() {
        let (rules, _) = compile_rules(&IndexOptions::default().toc_rules);
        let lines = [
            "第一章 假装第一章前面有空白但我不要",
            "　　第一章 假装第一章前面有空白但我不要",
            "　　序章 序章也算一章",
            "　　楔子",
            "　　正文 故事开始了",
            "　　正文完",
            "　　终章 结束",
            "　　后记",
            "　　尾声",
            "　　番外 其一",
            "　　第三章",
            "　　第二卷 上",
            "　　第一部 起",
            "　　第五篇 风",
            "他走进了第一章的大门",
            "",
            "　　",
        ];
        for line in lines {
            let line = units(line);
            if match_rule(&rules, &line).is_some() {
                assert!(
                    could_match_default_rules(&line),
                    "预过滤丢掉了本应匹配的行：{}",
                    lossy(&line)
                );
            }
        }
    }

    #[test]
    fn default_rules_match_the_frozen_examples() {
        let (rules, ignored) = compile_rules(&IndexOptions::default().toc_rules);
        assert!(ignored.is_empty());
        assert_eq!(
            match_rule_text(&rules, "第一章 假装第一章前面有空白但我不要").as_deref(),
            Some("第一章 假装第一章前面有空白但我不要"),
        );
        // The lookbehind rule strips the leading whitespace from the title;
        // Dart's RegExp cannot express this, which is why the pass lives here.
        assert_eq!(
            match_rule_text(&rules, "　　第一章 假装第一章前面有空白但我不要").as_deref(),
            Some("第一章 假装第一章前面有空白但我不要"),
        );
        assert_eq!(match_rule_text(&rules, "他走进了第一章的大门"), None);
        assert_eq!(match_rule_text(&rules, ""), None);
    }

    #[test]
    fn a_rule_that_does_not_compile_is_ignored() {
        let (rules, ignored) = compile_rules(&["(unclosed".to_string()]);
        assert!(rules.is_empty());
        assert_eq!(ignored, vec!["(unclosed".to_string()]);
    }
}
