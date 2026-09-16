//! The engine against real files: detection, one-pass indexing, window reads,
//! and the encodings `dart:convert` cannot touch.
//!
//! The fixtures carry their own provenance (`tests/data/README.md`) and their
//! lengths here are the numbers a reader of the fixtures computes by hand, not
//! numbers produced by this code — an off-by-one in the offsets has to fail
//! here, not agree with itself.

use std::fs;
use std::path::{Path, PathBuf};

use liber_text::{
    Anchor, Direction, IndexOptions, TextError, convert, detect_encoding, index_file, read_window,
};

const BOOK_BYTES: u64 = 46_585;
const BOOK_CODE_UNITS: u64 = 15_635;
const BOOK_LINES: usize = 74;
const CHAPTERED_BYTES: u64 = 14_095;
const CHAPTERED_CODE_UNITS: u64 = 4_731;

fn data(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data")
        .join(name)
}

/// A scratch directory for one test; the caller's name keeps tests apart.
fn scratch(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("liber-text-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).expect("无法创建测试临时目录");
    path
}

fn book_text() -> String {
    fs::read_to_string(data("sample_book.txt")).expect("fixture 读取失败")
}

fn utf16_units(text: &str) -> u64 {
    text.encode_utf16().count() as u64
}

/// The window that starts at `offset`, using the nearest stored anchor, the way
/// the reader does it.
fn window_at(path: &Path, index: &liber_text::Index, offset: u64, size: usize) -> String {
    let anchor = index
        .anchors
        .iter()
        .rev()
        .find(|anchor| anchor.code_unit_offset <= offset)
        .copied();
    read_window(
        path,
        &index.encoding,
        anchor,
        offset,
        size,
        IndexOptions::default().max_scan_bytes,
    )
    .expect("窗口读取失败")
    .text
}

#[test]
fn utf8_book_indexes_exactly() {
    let path = data("sample_book.txt");
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    assert_eq!(index.encoding, "UTF-8");
    assert_eq!(index.byte_length, BOOK_BYTES);
    assert_eq!(index.byte_length, fs::metadata(&path).unwrap().len());
    assert_eq!(index.code_unit_length, BOOK_CODE_UNITS);
    assert_eq!(index.code_unit_length, utf16_units(&book_text()));
    assert_eq!(index.ignored_rules, Vec::<String>::new());
    // The wiki's chapters carry no 章/节 headings, so the default rules find
    // nothing and the caller gets one implicit chapter (D4).
    assert!(
        index.chapters.is_empty(),
        "未预期的章节：{:?}",
        index.chapters
    );

    assert_eq!(
        index.anchors[0],
        Anchor {
            byte_offset: 0,
            code_unit_offset: 0,
            line_index: 0
        }
    );
    assert!(index.anchors.len() > 1, "锚点太稀：{}", index.anchors.len());
    for pair in index.anchors.windows(2) {
        let (before, after) = (pair[0], pair[1]);
        assert!(after.byte_offset > before.byte_offset);
        assert!(after.code_unit_offset > before.code_unit_offset);
        assert!(after.line_index > before.line_index);
        assert!(
            after.byte_offset - before.byte_offset >= IndexOptions::default().anchor_stride_bytes,
            "锚点间距小于步长：{before:?} {after:?}",
        );
    }
    assert!(
        index.anchors.last().unwrap().line_index < BOOK_LINES as u64,
        "锚点行号越过文件末尾",
    );
}

#[test]
fn windows_put_the_book_back_together() {
    let path = data("sample_book.txt");
    let text = book_text();
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    // Walk the book in windows that are not line-aligned, which is what a
    // reader's scrolling does, and reassemble it.
    const WINDOW: usize = 1_000;
    let mut assembled = String::new();
    let mut offset = 0u64;
    while offset < index.code_unit_length {
        let window = window_at(&path, &index, offset, WINDOW);
        assert!(!window.is_empty(), "偏移 {offset} 处窗口为空");
        assert!(
            utf16_units(&window) <= WINDOW as u64,
            "窗口超过了请求的 {WINDOW} 个码元",
        );
        assembled.push_str(&window);
        offset += utf16_units(&window);
    }
    assert_eq!(assembled, text);
}

#[test]
fn a_window_can_start_inside_a_paragraph() {
    let path = data("sample_book.txt");
    let text = book_text();
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    let units: Vec<u16> = text.encode_utf16().collect();
    for offset in [1u64, 37, 512, 4_096, index.code_unit_length - 3] {
        let window = window_at(&path, &index, offset, 64);
        let expected: String = String::from_utf16_lossy(
            &units[offset as usize..(offset as usize + 64).min(units.len())],
        );
        assert_eq!(window, expected, "偏移 {offset} 处窗口不符");
    }
}

#[test]
fn the_last_window_reports_the_end_of_the_file() {
    let path = data("sample_book.txt");
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    let tail = window_at(&path, &index, index.code_unit_length - 5, 1_000);
    assert_eq!(utf16_units(&tail), 5);
    let anchor = index.anchors.last().copied();
    let window = read_window(
        &path,
        "UTF-8",
        anchor,
        index.code_unit_length - 5,
        1_000,
        1 << 20,
    )
    .expect("窗口读取失败");
    assert!(window.at_end, "文件末尾的窗口没有报告 at_end");
    let full = read_window(&path, "UTF-8", Some(index.anchors[0]), 0, 1_000, 1 << 20)
        .expect("窗口读取失败");
    assert!(!full.at_end, "未到文件末尾的窗口报告了 at_end");
}

#[test]
fn chapters_come_from_the_frozen_default_rules() {
    let path = data("chaptered_book.txt");
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    assert_eq!(index.byte_length, CHAPTERED_BYTES);
    assert_eq!(index.code_unit_length, CHAPTERED_CODE_UNITS);
    let chapters: Vec<(String, u64, u64, u64)> = index
        .chapters
        .iter()
        .map(|chapter| {
            (
                chapter.title.clone(),
                chapter.byte_offset,
                chapter.code_unit_offset,
                chapter.line_index,
            )
        })
        .collect();
    assert_eq!(
        chapters,
        vec![
            (
                "第一章 宴桃園豪傑三結義　斬黃巾英雄首立功".to_string(),
                0,
                0,
                0
            ),
            (
                "第二章 張翼德怒鞭督郵　何國舅謀誅宦豎".to_string(),
                7_598,
                2_544,
                8
            ),
            (
                "第三章 議溫明董卓叱丁原　饋金珠李肅說呂布".to_string(),
                9_521,
                3_197,
                16
            ),
        ],
    );
    // A window opened at a chapter's code-unit offset starts at its line, which
    // includes the indentation the rule's lookbehind keeps out of the title.
    let text = window_at(&path, &index, index.chapters[1].code_unit_offset, 8);
    assert_eq!(text, "　　第二章 張翼");
}

#[test]
fn gbk_book_decodes_to_the_same_text() {
    let utf8 = data("chaptered_book.txt");
    let text = fs::read_to_string(&utf8).expect("fixture 读取失败");
    let (bytes, _, had_errors) = encoding_rs::GBK.encode(&text);
    assert!(!had_errors, "GBK 无法表示这份 fixture");
    let path = scratch("gbk").join("book.txt");
    fs::write(&path, &bytes).expect("写入失败");

    let detection = detect_encoding(&path).expect("检测失败");
    assert!(
        detection.encoding == "GBK" || detection.encoding == "gb18030",
        "GBK 文件被识别为 {}",
        detection.encoding,
    );
    assert!(!detection.bom);

    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    assert_eq!(index.code_unit_length, CHAPTERED_CODE_UNITS);
    assert_eq!(index.chapters.len(), 3);
    // Byte offsets follow the encoded file, code-unit offsets the decoded text.
    assert!(
        index.byte_length < CHAPTERED_BYTES,
        "GBK 文件不该比 UTF-8 大"
    );
    assert_eq!(index.anchors[0].byte_offset, 0);
    let window = window_at(&path, &index, 0, 24);
    assert_eq!(window, "　　第一章 宴桃園豪傑三結義　斬黃巾英雄首立功\n");
}

#[test]
fn big5_lines_decode_to_the_same_text() {
    // Big5 has no mapping for a few characters of the excerpt (裏, 妳), so the
    // fixture is built from lines it can hold.
    let lines = [
        "　　詞曰：",
        "　　滾滾長江東逝水，浪花淘盡英雄。",
        "　　話說天下大勢，分久必合，合久必分。",
        "　　玄德曰：「我三人義同生死，豈可相離？」",
    ];
    let text = lines.join("\n") + "\n";
    let (bytes, _, had_errors) = encoding_rs::BIG5.encode(&text);
    assert!(!had_errors, "Big5 无法表示测试文本");
    let path = scratch("big5").join("book.txt");
    fs::write(&path, &bytes).expect("写入失败");

    assert_eq!(detect_encoding(&path).expect("检测失败").encoding, "Big5");
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    assert_eq!(index.code_unit_length, utf16_units(&text));
    assert_eq!(window_at(&path, &index, 0, usize::MAX / 2), text);
}

#[test]
fn utf16_with_a_byte_order_mark_keeps_its_offsets() {
    let text = "第一章 测试\n　　鲁智深倒拔垂杨柳，武松打虎。\n";
    let mut bytes = vec![0xFF, 0xFE];
    for unit in text.encode_utf16() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    let path = scratch("utf16").join("book.txt");
    fs::write(&path, &bytes).expect("写入失败");

    let detection = detect_encoding(&path).expect("检测失败");
    assert_eq!(detection.encoding, "UTF-16LE");
    assert!(detection.bom);
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    assert_eq!(index.code_unit_length, utf16_units(text));
    assert_eq!(index.byte_length, bytes.len() as u64);
    // The mark itself is not text: the first anchor sits after it.
    assert_eq!(index.anchors[0].byte_offset, 2);
    assert_eq!(index.anchors[0].code_unit_offset, 0);
    assert_eq!(index.chapters.len(), 1);
    assert_eq!(window_at(&path, &index, 0, 1_000), text);
}

#[test]
fn utf8_byte_order_mark_is_part_of_no_window() {
    let text = "第一章 测试\n　　正文。\n";
    let mut bytes = vec![0xEF, 0xBB, 0xBF];
    bytes.extend_from_slice(text.as_bytes());
    let path = scratch("utf8-bom").join("book.txt");
    fs::write(&path, &bytes).expect("写入失败");

    let detection = detect_encoding(&path).expect("检测失败");
    assert_eq!(detection.encoding, "UTF-8");
    assert!(detection.bom);
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    assert_eq!(index.anchors[0].byte_offset, 3);
    assert_eq!(index.code_unit_length, utf16_units(text));
    assert_eq!(window_at(&path, &index, 0, 1_000), text);
}

#[test]
fn crlf_lines_keep_their_byte_offsets_and_their_markers() {
    let text = "第一章 起点\r\n　　第一段。\r\n\r\n　　第二段。\r\n";
    let path = scratch("crlf").join("book.txt");
    fs::write(&path, text).expect("写入失败");

    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    assert_eq!(index.code_unit_length, utf16_units(text));
    assert_eq!(index.byte_length, text.len() as u64);
    // The rule matches the line without its terminator, so CRLF does not change
    // which lines are chapters.
    assert_eq!(index.chapters.len(), 1);
    assert_eq!(index.chapters[0].title, "第一章 起点");
    assert_eq!(window_at(&path, &index, 0, 1_000), text);
}

#[test]
fn non_bmp_characters_cost_two_code_units() {
    let text = "㑮𫝈𠀋\n第二行\n";
    let path = scratch("non-bmp").join("book.txt");
    fs::write(&path, text).expect("写入失败");
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    // 㑮=1 unit, 𫝈=2, 𠀋=2, newline=1, 第二行=3, newline=1.
    assert_eq!(index.code_unit_length, 10);
    assert_eq!(index.byte_length, text.len() as u64);
    // A window opened at a character boundary returns whole characters.
    assert_eq!(window_at(&path, &index, 1, 1_000), "𫝈𠀋\n第二行\n");
    assert_eq!(window_at(&path, &index, 3, 1_000), "𠀋\n第二行\n");
}

#[test]
fn a_stale_anchor_is_an_error_not_a_full_read() {
    let path = data("sample_book.txt");
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    let error = read_window(&path, "UTF-8", None, index.code_unit_length - 1, 100, 4_096)
        .expect_err("没有锚点又超过扫描上限，应当报错");
    match error {
        TextError::AnchorTooFar {
            scanned_bytes,
            limit,
        } => {
            assert!(
                scanned_bytes > limit,
                "报告了 {scanned_bytes} 字节，上限 {limit}"
            );
            assert_eq!(limit, 4_096);
        }
        other => panic!("期望 AnchorTooFar，得到 {other:?}"),
    }
    // With an anchor near the target the same read succeeds.
    let window = window_at(&path, &index, index.code_unit_length - 1, 100);
    assert_eq!(utf16_units(&window), 1);
}

#[test]
fn an_offset_past_the_end_is_an_error() {
    let path = data("sample_book.txt");
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    let error = read_window(
        &path,
        "UTF-8",
        index.anchors.last().copied(),
        index.code_unit_length + 10,
        100,
        1 << 20,
    )
    .expect_err("越过文件末尾的偏移应当报错");
    match error {
        TextError::OffsetOutOfRange {
            offset,
            code_unit_length,
        } => {
            assert_eq!(offset, index.code_unit_length + 10);
            assert!(code_unit_length <= index.code_unit_length);
        }
        other => panic!("期望 OffsetOutOfRange，得到 {other:?}"),
    }
}

#[test]
fn utf32_and_unknown_names_are_refused() {
    let path = scratch("utf32").join("book.txt");
    fs::write(&path, [0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]).expect("写入失败");
    match detect_encoding(&path) {
        Err(TextError::UnsupportedEncoding(name)) => assert_eq!(name, "UTF-32LE"),
        other => panic!("期望拒绝 UTF-32，得到 {other:?}"),
    }
    match read_window(&data("sample_book.txt"), "Klingon", None, 0, 10, 1 << 20) {
        Err(TextError::UnknownEncoding(name)) => assert_eq!(name, "Klingon"),
        other => panic!("期望拒绝未知编码，得到 {other:?}"),
    }
}

#[test]
fn detection_ignores_an_ascii_head_and_still_decodes_the_body() {
    // A table of contents in ASCII, then GBK text: the sample a detector reads
    // first must not settle the answer.
    let mut text = String::new();
    for chapter in 1..=40 {
        text.push_str(&format!(
            "Chapter {chapter} ................ page {chapter}\n"
        ));
    }
    text.push_str("　　第一章 测试\n　　这是中文正文。\n");
    let (bytes, _, had_errors) = encoding_rs::GBK.encode(&text);
    assert!(!had_errors);
    let path = scratch("ascii-head").join("book.txt");
    fs::write(&path, &bytes).expect("写入失败");

    let detection = detect_encoding(&path).expect("检测失败");
    assert!(
        detection.encoding == "GBK" || detection.encoding == "gb18030",
        "ASCII 开头之后的中文被识别为 {}",
        detection.encoding,
    );
    let index = index_file(&path, &IndexOptions::default()).expect("索引失败");
    assert_eq!(index.code_unit_length, utf16_units(&text));
    let tail = window_at(&path, &index, index.code_unit_length - 8, 8);
    assert_eq!(tail, "这是中文正文。\n");
}

#[test]
fn conversion_is_available_where_indexing_is() {
    // The engine's two halves meet in one crate: conversion is not a separate
    // library the reader would have to load.
    assert_eq!(
        convert(
            "　　蘇貞昌與韓國瑜在臺上握手。",
            Direction::TraditionalToSimplified
        ),
        "　　苏贞昌与韩国瑜在台上握手。",
    );
    assert_eq!(
        convert(
            "龙应台的小说在台湾很受欢迎。",
            Direction::SimplifiedToTraditional
        ),
        "龍應臺的小說在臺灣很受歡迎。",
    );
}
