//! THROWAWAY: the text engine alone, without any Dart VM in the process.
//!
//! The Dart benchmark (`text_engine_bench.dart`) measures the engine where the
//! product uses it — inside a Dart process, through the bridge — but that
//! process's floor is the Dart VM (a quarter of a gigabyte for `dart run`), so
//! it cannot answer the contract's "peak RSS under ~50 MB for 500 MB" for the
//! engine itself. This binary runs the same crate in a bare process and reports
//! the process peak.
//!
//! Usage: rust_bench <index|window|convert> <parameters.json> <result.json>
//!
//! Parameters match the Dart harness: `index` takes `path`, `stride`,
//! `anchors_out`; `window` takes `path`, `encoding`, `anchors_in`, `offset`,
//! `max_code_units`, `max_scan_bytes`; `convert` takes `traditional` and
//! `simplified` file paths.

use std::fs;
use std::path::Path;
use std::time::Instant;

use liber_text::{Anchor, ConvertTarget, Direction, IndexOptions, convert, convert_to, index_file, read_window};

/// The process's peak resident set size, from the operating system's own
/// counters. Windows: `GetProcessMemoryInfo(...).PeakWorkingSetSize`. Linux:
/// `/proc/self/status` `VmHWM`. Other hosts: none, and the record says so.
#[cfg(windows)]
fn peak_rss_bytes() -> Option<u64> {
    #[repr(C)]
    #[derive(Default)]
    struct Counters {
        cb: u32,
        page_faults: u32,
        peak_working_set: usize,
        working_set: usize,
        quota_peak_paged: usize,
        quota_paged: usize,
        quota_peak_non_paged: usize,
        quota_non_paged: usize,
        pagefile: usize,
        peak_pagefile: usize,
    }

    unsafe extern "system" {
        fn GetCurrentProcess() -> *mut core::ffi::c_void;
    }
    #[link(name = "psapi")]
    unsafe extern "system" {
        fn GetProcessMemoryInfo(
            process: *mut core::ffi::c_void,
            counters: *mut Counters,
            cb: u32,
        ) -> i32;
    }

    let mut counters = Counters { cb: std::mem::size_of::<Counters>() as u32, ..Default::default() };
    // SAFETY: `Counters` is the documented PROCESS_MEMORY_COUNTERS layout for
    // 64-bit Windows, it is alive across the call, and `GetCurrentProcess` is a
    // pseudo-handle that needs no release.
    let ok = unsafe { GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, counters.cb) };
    (ok != 0).then_some(counters.peak_working_set as u64)
}

#[cfg(target_os = "linux")]
fn peak_rss_bytes() -> Option<u64> {
    let status = fs::read_to_string("/proc/self/status").ok()?;
    for line in status.lines() {
        if let Some(value) = line.strip_prefix("VmHWM:") {
            let kilobytes: u64 = value.split_whitespace().next()?.parse().ok()?;
            return Some(kilobytes * 1024);
        }
    }
    None
}

#[cfg(not(any(windows, target_os = "linux")))]
fn peak_rss_bytes() -> Option<u64> {
    None
}

/// The tiny JSON reader the parameters need: flat objects, numbers, strings and
/// arrays of numbers. A dependency-free stand-in for the two files this
/// harness reads.
fn json_field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let start = text.find(&format!("\"{key}\""))? + key.len() + 2;
    let rest = text[start..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    if let Some(rest) = rest.strip_prefix('"') {
        let end = rest.find('"')?;
        return Some(&rest[..end]);
    }
    let end = rest.find([',', '}', '\n']).unwrap_or(rest.len());
    Some(rest[..end].trim())
}

fn number(text: &str, key: &str) -> Option<u64> {
    json_field(text, key)?.parse().ok()
}

/// The anchors a previous `index` run wrote: an array of `[byte, units, line]`.
fn anchors(path: &str) -> Vec<Anchor> {
    let text = fs::read_to_string(path).expect("cannot read the anchors file");
    let mut anchors = Vec::new();
    let mut numbers = Vec::new();
    let mut current = String::new();
    for character in text.chars() {
        if character.is_ascii_digit() {
            current.push(character);
            continue;
        }
        if !current.is_empty() {
            numbers.push(current.parse::<u64>().expect("anchor is not a number"));
            current.clear();
        }
        if character == ']' {
            if numbers.len() == 3 {
                anchors.push(Anchor {
                    byte_offset: numbers[0],
                    code_unit_offset: numbers[1],
                    line_index: numbers[2],
                });
            }
            numbers.clear();
        }
    }
    anchors
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: rust_bench <index|window|convert> <parameters.json> <result.json>");
        std::process::exit(2);
    }
    let (phase, parameters_path, result_path) = (&args[1], &args[2], &args[3]);
    let parameters = fs::read_to_string(parameters_path).expect("cannot read the parameters");
    let baseline = peak_rss_bytes();
    let watch = Instant::now();
    let body = match phase.as_str() {
        "index" => {
            let path = json_field(&parameters, "path").expect("path");
            let stride = number(&parameters, "stride").unwrap_or(32 * 1024);
            let options = IndexOptions {
                anchor_stride_bytes: stride,
                ..IndexOptions::default()
            };
            let index = index_file(Path::new(path), &options).expect("index failed");
            if let Some(out) = json_field(&parameters, "anchors_out") {
                let mut text = String::from("[");
                for (number, anchor) in index.anchors.iter().enumerate() {
                    if number > 0 {
                        text.push(',');
                    }
                    text.push_str(&format!(
                        "[{},{},{}]",
                        anchor.byte_offset, anchor.code_unit_offset, anchor.line_index
                    ));
                }
                text.push(']');
                fs::write(out, text).expect("cannot write the anchors");
            }
            format!(
                "\"encoding\":\"{}\",\"bytes\":{},\"code_units\":{},\"anchors\":{},\"chapters\":{}",
                index.encoding,
                index.byte_length,
                index.code_unit_length,
                index.anchors.len(),
                index.chapters.len(),
            )
        }
        "window" => {
            let path = json_field(&parameters, "path").expect("path");
            let encoding = json_field(&parameters, "encoding").expect("encoding");
            let offset = number(&parameters, "offset").expect("offset");
            let max_code_units = number(&parameters, "max_code_units").expect("max_code_units");
            let max_scan_bytes = number(&parameters, "max_scan_bytes").unwrap_or(4 * 1024 * 1024);
            let anchor = if let Some(anchors_in) = json_field(&parameters, "anchors_in") {
                anchors(anchors_in)
                    .into_iter()
                    .rev()
                    .find(|anchor| anchor.code_unit_offset <= offset)
            } else {
                None
            };
            let window = read_window(
                Path::new(path),
                encoding,
                anchor,
                offset,
                max_code_units as usize,
                max_scan_bytes,
            )
            .expect("window failed");
            format!(
                "\"code_units\":{},\"at_end\":{},\"line_index\":{}",
                window.text.encode_utf16().count(),
                window.at_end,
                window.line_index,
            )
        }
        "convert" => {
            let traditional_path = json_field(&parameters, "traditional").expect("traditional");
            let simplified_path = json_field(&parameters, "simplified").expect("simplified");
            let traditional = fs::read_to_string(traditional_path).expect("cannot read the text");
            let simplified = fs::read_to_string(simplified_path).expect("cannot read the text");
            // Load every table first, so the timings below are conversion and the
            // load figures are the cost of parsing the embedded tables once per
            // process (they are lazy, so the first call pays for them).
            let warm_up = "这段文字很短。";
            let start = Instant::now();
            let _ = liber_text::convert_to(warm_up, ConvertTarget::SimplifiedMainland);
            let load_t2s_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let _ = liber_text::convert_to(warm_up, ConvertTarget::TraditionalGeneric);
            let load_generic_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let _ = liber_text::convert_to(warm_up, ConvertTarget::TraditionalTaiwan);
            let load_taiwan_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let _ = liber_text::convert_to(warm_up, ConvertTarget::TraditionalHongKong);
            let load_hong_kong_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let _ = convert(warm_up, Direction::TraditionalToSimplified);
            let load_t2s_characters_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let to_simplified = liber_text::convert_to(&traditional, ConvertTarget::SimplifiedMainland);
            let cold_t2s_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let _ = liber_text::convert_to(&traditional, ConvertTarget::SimplifiedMainland);
            let warm_t2s_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let to_traditional = liber_text::convert_to(&simplified, ConvertTarget::TraditionalGeneric);
            let warm_generic_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let _ = liber_text::convert_to(&simplified, ConvertTarget::TraditionalTaiwan);
            let warm_taiwan_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let _ = liber_text::convert_to(&simplified, ConvertTarget::TraditionalHongKong);
            let warm_hong_kong_micros = start.elapsed().as_micros();
            // The character-only paths, which `java.t2s`/`java.s2t` call.
            let start = Instant::now();
            let _ = convert(&traditional, Direction::TraditionalToSimplified);
            let warm_t2s_characters_micros = start.elapsed().as_micros();
            let start = Instant::now();
            let _ = convert(&simplified, Direction::SimplifiedToTraditional);
            let warm_s2t_characters_micros = start.elapsed().as_micros();
            format!(
                "\"t2s_code_units\":{},\"s2t_code_units\":{},\"t2s_micros\":{},\"s2t_micros\":{},\"t2s_changed\":{},\"s2t_changed\":{},\"cold_t2s_micros\":{},\"warm_t2s_micros\":{},\"warm_generic_micros\":{},\"warm_taiwan_micros\":{},\"warm_hong_kong_micros\":{},\"warm_t2s_characters_micros\":{},\"warm_s2t_characters_micros\":{},\"load_t2s_micros\":{},\"load_generic_micros\":{},\"load_taiwan_micros\":{},\"load_hong_kong_micros\":{},\"load_t2s_characters_micros\":{}",
                traditional.encode_utf16().count(),
                simplified.encode_utf16().count(),
                warm_t2s_micros,
                warm_generic_micros,
                u8::from(to_simplified != traditional),
                u8::from(to_traditional != simplified),
                cold_t2s_micros,
                warm_t2s_micros,
                warm_generic_micros,
                warm_taiwan_micros,
                warm_hong_kong_micros,
                warm_t2s_characters_micros,
                warm_s2t_characters_micros,
                load_t2s_micros,
                load_generic_micros,
                load_taiwan_micros,
                load_hong_kong_micros,
                load_t2s_characters_micros,
            )
        }
        other => {
            eprintln!("unknown phase {other}");
            std::process::exit(2);
        }
    };
    let elapsed = watch.elapsed();
    let peak = peak_rss_bytes();
    let record = format!(
        "{{\"phase\":\"rust-bench-{}\",{},\"elapsed_micros\":{},\"baseline_rss_bytes\":{},\"peak_rss_bytes\":{},\"platform\":\"{}\"}}\n",
        phase,
        body,
        elapsed.as_micros(),
        baseline.map(|value| value.to_string()).unwrap_or_else(|| "null".into()),
        peak.map(|value| value.to_string()).unwrap_or_else(|| "null".into()),
        std::env::consts::OS,
    );
    fs::write(result_path, &record).expect("cannot write the result");
    print!("{record}");
}
