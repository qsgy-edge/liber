//! # Text Engine API
//!
//! The product's entry to `liber_text`: what a local file is, one pass that
//! indexes it, bounded window reads, and the frozen reader's Chinese
//! conversion.
//!
//! `docs/user-data-contract.md` D4/D10 decide the shape. A local TXT is decoded
//! once and indexed into `text_index` (sparse byte ↔ code-unit anchors at line
//! starts plus chapter boundaries); the reader afterwards asks for a window of a
//! few tens of KB around a stored offset and never for the whole book. Index and
//! window calls are asynchronous on purpose — the decode happens on a worker
//! thread, not on the UI isolate — while conversion is synchronous, because a
//! Book Source rule evaluates `java.t2s` inside its own script.

use flutter_rust_bridge::frb;
use liber_text as engine;

/// Offsets, lengths and limits cross the bridge as `i64`: Dart's `int` is 64
/// bits wide on every platform this product ships, while `frb`'s `u64` becomes
/// a `BigInt` a reader would have to unwrap around every offset. The engine
/// never produces a negative value, and a caller that passes one gets the same
/// answer as if it had passed a value past the end of the file.
fn units(value: i64) -> u64 {
    value as u64
}

/// Which way to convert.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextDirection {
    /// `java.t2s`, the reader's 简体 setting.
    TraditionalToSimplified,
    /// `java.s2t`, the reader's 繁體 setting.
    SimplifiedToTraditional,
}

impl From<TextDirection> for engine::Direction {
    fn from(direction: TextDirection) -> Self {
        match direction {
            TextDirection::TraditionalToSimplified => engine::Direction::TraditionalToSimplified,
            TextDirection::SimplifiedToTraditional => engine::Direction::SimplifiedToTraditional,
        }
    }
}

/// What went wrong: the same cases the Rust engine reports, in a shape a Dart
/// caller can switch on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TextEngineError {
    /// The file could not be read.
    Io(String),
    /// The encoding name is not one the Encoding Standard knows.
    UnknownEncoding(String),
    /// The file's byte order mark names an encoding the engine does not decode.
    UnsupportedEncoding(String),
    /// The anchors handed in are stale: the scan from the anchor passed the
    /// caller's limit.
    AnchorTooFar {
        /// Bytes scanned before giving up.
        scanned_bytes: i64,
        /// The caller's limit.
        limit: i64,
    },
    /// The requested offset is past the end of the file.
    OffsetOutOfRange {
        /// The requested code-unit offset.
        offset: i64,
        /// The file's code-unit length.
        code_unit_length: i64,
    },
}

impl From<engine::TextError> for TextEngineError {
    fn from(error: engine::TextError) -> Self {
        match error {
            engine::TextError::Io(message) => TextEngineError::Io(message),
            engine::TextError::UnknownEncoding(name) => TextEngineError::UnknownEncoding(name),
            engine::TextError::UnsupportedEncoding(name) => {
                TextEngineError::UnsupportedEncoding(name)
            }
            engine::TextError::AnchorTooFar { scanned_bytes, limit } => {
                TextEngineError::AnchorTooFar {
                    scanned_bytes: scanned_bytes as i64,
                    limit: limit as i64,
                }
            }
            engine::TextError::OffsetOutOfRange { offset, code_unit_length } => {
                TextEngineError::OffsetOutOfRange {
                    offset: offset as i64,
                    code_unit_length: code_unit_length as i64,
                }
            }
        }
    }
}

/// Encoding detection's answer for one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextDetection {
    /// The Encoding Standard name (`UTF-8`, `GBK`, `Big5`, …).
    pub encoding: String,
    /// Whether the name came from a byte order mark.
    pub bom: bool,
}

/// One sparse anchor: a line start in bytes, in code units, and in lines. These
/// are the `text_index` rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextAnchor {
    /// Byte offset in the file.
    pub byte_offset: i64,
    /// UTF-16 code-unit offset in the decoded text.
    pub code_unit_offset: i64,
    /// Zero-based line index.
    pub line_index: i64,
}

/// One chapter boundary, as the TOC rules found it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextChapter {
    /// The matched text, without the whitespace a rule's lookbehind excludes.
    pub title: String,
    /// Byte offset of the chapter's line start.
    pub byte_offset: i64,
    /// Code-unit offset of the same position.
    pub code_unit_offset: i64,
    /// Zero-based line index of the same position.
    pub line_index: i64,
}

/// How to index a file.
#[derive(Debug, Clone)]
pub struct TextIndexOptions {
    /// One anchor at least every this many bytes, aligned to a line start.
    pub anchor_stride_bytes: i64,
    /// TOC rules in the frozen reader's order. Empty means no chapter
    /// detection.
    pub toc_rules: Vec<String>,
    /// The longest anchor-to-target scan a window read may perform.
    pub max_scan_bytes: i64,
}

/// The defaults the frozen reader starts from: one anchor per 32 KiB, its two
/// enabled default TXT rules, and a 4 MiB scan limit.
#[frb(sync)]
pub fn text_default_options() -> TextIndexOptions {
    let options = engine::IndexOptions::default();
    TextIndexOptions {
        anchor_stride_bytes: options.anchor_stride_bytes as i64,
        toc_rules: options.toc_rules,
        max_scan_bytes: options.max_scan_bytes as i64,
    }
}

/// One pass over a local file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextIndex {
    /// The detected encoding's name.
    pub encoding: String,
    /// The file's size in bytes.
    pub byte_length: i64,
    /// The file's length in UTF-16 code units.
    pub code_unit_length: i64,
    /// Line starts, sparse by the anchor stride.
    pub anchors: Vec<TextAnchor>,
    /// Chapter boundaries, empty when no rule matched.
    pub chapters: Vec<TextChapter>,
    /// Rules that do not compile. The frozen reader ignores them and opens the
    /// book without them.
    pub ignored_rules: Vec<String>,
}

/// A window read request.
#[derive(Debug, Clone)]
pub struct TextWindowRequest {
    /// The file to read.
    pub path: String,
    /// The encoding name from the index that produced the anchor.
    pub encoding: String,
    /// The nearest anchor the caller has stored, if any.
    pub anchor: Option<TextAnchor>,
    /// The code-unit offset the window starts at.
    pub code_unit_offset: i64,
    /// How many code units at most.
    pub max_code_units: i64,
    /// The longest scan from the anchor before the read reports stale anchors.
    pub max_scan_bytes: i64,
}

/// A bounded read's answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextWindow {
    /// The decoded text.
    pub text: String,
    /// The code-unit offset the window starts at.
    pub code_unit_offset: i64,
    /// The byte offset the window starts at.
    pub byte_offset: i64,
    /// The line the window starts in.
    pub line_index: i64,
    /// Whether the window ends at the end of the file.
    pub at_end: bool,
}

/// Detects a file's encoding.
pub fn text_detect_encoding(path: String) -> Result<TextDetection, TextEngineError> {
    let detection = engine::detect_encoding(std::path::Path::new(&path))?;
    Ok(TextDetection { encoding: detection.encoding, bom: detection.bom })
}

/// Indexes a local file in one pass: encoding, both lengths, anchors, chapters.
pub fn text_index_file(
    path: String,
    options: TextIndexOptions,
) -> Result<TextIndex, TextEngineError> {
    let options = engine::IndexOptions {
        anchor_stride_bytes: units(options.anchor_stride_bytes),
        toc_rules: options.toc_rules,
        max_scan_bytes: units(options.max_scan_bytes),
    };
    let index = engine::index_file(std::path::Path::new(&path), &options)?;
    Ok(TextIndex {
        encoding: index.encoding,
        byte_length: index.byte_length as i64,
        code_unit_length: index.code_unit_length as i64,
        anchors: index
            .anchors
            .into_iter()
            .map(|anchor| TextAnchor {
                byte_offset: anchor.byte_offset as i64,
                code_unit_offset: anchor.code_unit_offset as i64,
                line_index: anchor.line_index as i64,
            })
            .collect(),
        chapters: index
            .chapters
            .into_iter()
            .map(|chapter| TextChapter {
                title: chapter.title,
                byte_offset: chapter.byte_offset as i64,
                code_unit_offset: chapter.code_unit_offset as i64,
                line_index: chapter.line_index as i64,
            })
            .collect(),
        ignored_rules: index.ignored_rules,
    })
}

/// Reads a bounded window of a local file.
pub fn text_read_window(
    request: TextWindowRequest,
) -> Result<TextWindow, TextEngineError> {
    let anchor = request.anchor.map(|anchor| engine::Anchor {
        byte_offset: units(anchor.byte_offset),
        code_unit_offset: units(anchor.code_unit_offset),
        line_index: units(anchor.line_index),
    });
    let window = engine::read_window(
        std::path::Path::new(&request.path),
        &request.encoding,
        anchor,
        units(request.code_unit_offset),
        units(request.max_code_units) as usize,
        units(request.max_scan_bytes),
    )?;
    Ok(TextWindow {
        text: window.text,
        code_unit_offset: window.code_unit_offset as i64,
        byte_offset: window.byte_offset as i64,
        line_index: window.line_index as i64,
        at_end: window.at_end,
    })
}

/// Converts Chinese text with the tables ADR 0009 records.
///
/// Synchronous because the frozen `java.t2s`/`java.s2t` are: a rule calls them
/// inside a script and uses the result immediately.
#[frb(sync)]
pub fn text_convert(text: String, direction: TextDirection) -> String {
    engine::convert(&text, direction.into())
}
