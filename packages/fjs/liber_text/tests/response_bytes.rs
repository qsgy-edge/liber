//! The engine's in-memory path: an HTTP response body's bytes decoded with a
//! declared charset or with the detector, and the request-side encoder the
//! `charset` request option needs.
//!
//! These are the two halves the Book Source request layer reaches through the
//! bridge. The frozen response path is `OkHttpUtils.kt:78-96` (`removeUTF8BOM`,
//! then the Content-Type charset, then `EncodingDetect.getHtmlEncode`), and the
//! frozen request path is `AnalyzeUrl.kt:294-334` (`URLEncoder.encode` for form
//! bodies and hutool's `queryEncoder` for GET queries, both fed the option's
//! charset). The rows here pin the engine's own behavior; the Dart side pins the
//! resolution order and the percent-escaping that sit on top.

use liber_text::{TextError, decode_bytes, detect_bytes, encode_bytes};

fn utf16_units(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

/// The text both the GBK and the UTF-8 fixture encode: CJK plus ASCII.
const SAMPLE: &str = "第一章 起点\n正文开始。";

#[test]
fn a_declared_charset_decodes_the_body() {
    let (gbk, had_errors) = gbk_bytes(SAMPLE);
    assert!(!had_errors, "GBK 无法表示这份 fixture");

    assert_eq!(decode_bytes(&gbk, Some("GBK")).expect("GBK 解码失败"), SAMPLE);
    // The label the Content-Type header carries is a label, not the canonical
    // name: the engine resolves aliases the way `Charset.forName` does.
    assert_eq!(decode_bytes(&gbk, Some("gb2312")).expect("gb2312 解码失败"), SAMPLE);
    // The declared charset decides the answer: the same bytes under another
    // label are not the same text.
    assert_ne!(
        decode_bytes(&gbk, Some("utf-8")).expect("UTF-8 解码失败"),
        SAMPLE
    );
}

#[test]
fn an_unknown_charset_is_refused_by_name() {
    let error = decode_bytes(b"abc", Some("no-such-charset")).expect_err("未知编码应当失败");
    assert_eq!(
        error,
        TextError::UnknownEncoding("no-such-charset".to_string())
    );
}

#[test]
fn a_label_free_decode_detects_the_charset() {
    let (gbk, _) = gbk_bytes(SAMPLE);
    assert_eq!(decode_bytes(&gbk, None).expect("检测解码失败"), SAMPLE);

    let detection = detect_bytes(&gbk).expect("检测失败");
    assert!(
        detection.encoding == "GBK" || detection.encoding == "gb18030",
        "GBK 字节被识别为 {}",
        detection.encoding
    );
    assert!(!detection.bom);
}

#[test]
fn malformed_bytes_become_replacement_characters() {
    // Java's `String(bytes, charset)` replaces a malformed sequence with
    // U+FFFD, and the encoded decoder does the same: the frozen path never
    // fails a body it can partly decode.
    let decoded = decode_bytes(&[0xE4, 0xB8], Some("UTF-8")).expect("解码失败");
    assert_eq!(decoded, "\u{FFFD}");
}

#[test]
fn a_byte_order_mark_is_stripped_only_when_the_engine_detects_it() {
    // The Dart side strips a UTF-8 BOM before it calls in (`removeUTF8BOM`), so
    // the named branch must not do it again; the detecting branch is what names
    // a BOM's encoding, so it consumes it.
    let mut utf8 = vec![0xEF, 0xBB, 0xBF];
    utf8.extend_from_slice(SAMPLE.as_bytes());
    assert_eq!(
        decode_bytes(&utf8, Some("UTF-8")).expect("解码失败"),
        format!("\u{FEFF}{SAMPLE}")
    );
    assert_eq!(decode_bytes(&utf8, None).expect("检测解码失败"), SAMPLE);

    let mut utf16: Vec<u8> = vec![0xFF, 0xFE];
    for unit in utf16_units(SAMPLE) {
        utf16.extend_from_slice(&unit.to_le_bytes());
    }
    assert_eq!(decode_bytes(&utf16, None).expect("UTF-16 解码失败"), SAMPLE);
}

#[test]
fn the_request_encoder_writes_the_charsets_bytes() {
    let (gbk, _) = gbk_bytes(SAMPLE);
    assert_eq!(
        encode_bytes(SAMPLE, "GBK").expect("GBK 编码失败"),
        gbk,
        "编码器写出的字节必须与解码器吃进的字节一致"
    );
    assert_eq!(
        encode_bytes(SAMPLE, "utf-8").expect("UTF-8 编码失败"),
        SAMPLE.as_bytes()
    );
}

#[test]
fn the_request_encoder_refuses_an_unknown_label() {
    let error = encode_bytes("a", "no-such-charset").expect_err("未知编码应当失败");
    assert_eq!(
        error,
        TextError::UnknownEncoding("no-such-charset".to_string())
    );
}

#[test]
fn a_character_the_charset_cannot_represent_is_not_dropped() {
    // `CharsetEncoder` REPLACE writes `?` here; `encoding_rs` writes the HTML
    // numeric character reference. The differential contract records the
    // divergence, and the crate pins which of the two this engine produces so a
    // dependency move cannot change it silently.
    let bytes = encode_bytes("😀", "GBK").expect("GBK 编码失败");
    assert_eq!(String::from_utf8(bytes).expect("NCR 是 ASCII"), "&#128512;");
}

/// The GBK bytes of `text`, through the same crate the product uses.
fn gbk_bytes(text: &str) -> (Vec<u8>, bool) {
    let (bytes, _used, had_errors) = encoding_rs::GBK.encode(text);
    (bytes.into_owned(), had_errors)
}
