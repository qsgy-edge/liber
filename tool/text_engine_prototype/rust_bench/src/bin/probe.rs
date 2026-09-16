//! THROWAWAY: isolate where the index pass spends its time, with the file's
//! pages already in the cache and each variant run three times.
//!
//! Usage: rust_bench_probe <path> <encoding label or 'auto'>

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;
use std::time::{Duration, Instant};

use encoding_rs::{Decoder, Encoding};
use liber_text::{IndexOptions, index_file};

fn warm(path: &str) {
    // Page the whole file in first: a 500 MB read off a cold disk is seconds of
    // I/O that would otherwise land inside whichever variant runs first.
    let mut file = File::open(path).unwrap();
    let mut buffer = vec![0u8; 8 * 1024 * 1024];
    let mut total = 0usize;
    loop {
        let read = file.read(&mut buffer).unwrap();
        if read == 0 {
            break;
        }
        total += read;
    }
    println!("warmed {total} bytes");
}

fn bulk_string(path: &str, encoding: &'static Encoding) -> Duration {
    let mut file = BufReader::with_capacity(256 * 1024, File::open(path).unwrap());
    let mut chunk = vec![0u8; 256 * 1024];
    let mut text = String::new();
    let mut decoder: Decoder = encoding.new_decoder_without_bom_handling();
    let watch = Instant::now();
    loop {
        let read = file.read(&mut chunk).unwrap();
        if read == 0 {
            break;
        }
        text.reserve(read * 4 + 8);
        let (_, consumed, _) = decoder.decode_to_string(&chunk[..read], &mut text, false);
        assert_eq!(consumed, read);
    }
    let elapsed = watch.elapsed();
    std::hint::black_box(text.len());
    elapsed
}

fn bulk_utf16(path: &str, encoding: &'static Encoding) -> Duration {
    let mut file = BufReader::with_capacity(256 * 1024, File::open(path).unwrap());
    let mut chunk = vec![0u8; 256 * 1024];
    let mut units: Vec<u16> = Vec::new();
    let mut decoder: Decoder = encoding.new_decoder_without_bom_handling();
    let watch = Instant::now();
    let mut written_total = 0usize;
    loop {
        let read = file.read(&mut chunk).unwrap();
        if read == 0 {
            break;
        }
        units.clear();
        units.resize(read + 8, 0);
        let (_, consumed, written, _) = decoder.decode_to_utf16(&chunk[..read], &mut units, false);
        assert_eq!(consumed, read);
        written_total += written;
    }
    let elapsed = watch.elapsed();
    std::hint::black_box(written_total);
    elapsed
}

fn index(path: &str, label: &str, options: &IndexOptions) -> Duration {
    let watch = Instant::now();
    let index = index_file(Path::new(path), options).unwrap();
    let elapsed = watch.elapsed();
    std::hint::black_box(index.anchors.len());
    println!(
        "  index_file ({label}): {} units, {} anchors, {elapsed:?}",
        index.code_unit_length,
        index.anchors.len()
    );
    elapsed
}

fn read_only(path: &str) -> Duration {
    let mut file = BufReader::with_capacity(256 * 1024, File::open(path).unwrap());
    let mut chunk = vec![0u8; 256 * 1024];
    let watch = Instant::now();
    let mut total = 0usize;
    loop {
        let read = file.read(&mut chunk).unwrap();
        if read == 0 {
            break;
        }
        total += read;
    }
    let elapsed = watch.elapsed();
    std::hint::black_box(total);
    elapsed
}

fn read_and_count_newlines(path: &str) -> Duration {
    let mut file = BufReader::with_capacity(256 * 1024, File::open(path).unwrap());
    let mut chunk = vec![0u8; 256 * 1024];
    let watch = Instant::now();
    let mut newlines = 0usize;
    loop {
        let read = file.read(&mut chunk).unwrap();
        if read == 0 {
            break;
        }
        newlines += chunk[..read].iter().filter(|byte| **byte == 10u8).count();
    }
    let elapsed = watch.elapsed();
    std::hint::black_box(newlines);
    elapsed
}

fn read_and_scan_units(path: &str, encoding: &'static Encoding) -> Duration {
    let mut file = BufReader::with_capacity(256 * 1024, File::open(path).unwrap());
    let mut chunk = vec![0u8; 256 * 1024];
    let mut units: Vec<u16> = Vec::new();
    let mut decoder: Decoder = encoding.new_decoder_without_bom_handling();
    let watch = Instant::now();
    let mut hits = 0usize;
    loop {
        let read = file.read(&mut chunk).unwrap();
        if read == 0 {
            break;
        }
        units.clear();
        units.resize(read + 8, 0);
        let (_, consumed, written, _) = decoder.decode_to_utf16(&chunk[..read], &mut units, false);
        assert_eq!(consumed, read);
        hits += units[..written]
            .iter()
            .filter(|unit| matches!(char::from_u32(u32::from(**unit)), Some('序')) || **unit == 0x7B2C || **unit == 0x540E)
            .count();
    }
    let elapsed = watch.elapsed();
    std::hint::black_box(hits);
    elapsed
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = &args[1];
    let label = args.get(2).map(String::as_str).unwrap_or("auto");
    let encoding = Encoding::for_label(
        if label == "auto" {
            liber_text::detect_encoding(Path::new(path)).unwrap().encoding
        } else {
            label.to_string()
        }
        .as_bytes(),
    )
    .unwrap();
    println!("encoding: {}", encoding.name());
    warm(path);
    for round in 1..=3 {
        println!("round {round}");
        println!("  read only:              {:?}", read_only(path));
        println!("  read + newline count:   {:?}", read_and_count_newlines(path));
        println!("  read + unit trigger scan: {:?}", read_and_scan_units(path, encoding));
        println!("  bulk decode -> String:  {:?}", bulk_string(path, encoding));
        println!("  bulk decode -> utf16:   {:?}", bulk_utf16(path, encoding));
        index(path, "default", &IndexOptions::default());
        index(
            path,
            "no rules",
            &IndexOptions {
                toc_rules: Vec::new(),
                ..IndexOptions::default()
            },
        );
        index(
            path,
            "no anchors, no rules",
            &IndexOptions {
                toc_rules: Vec::new(),
                anchor_stride_bytes: u64::MAX,
                ..IndexOptions::default()
            },
        );
    }
}
