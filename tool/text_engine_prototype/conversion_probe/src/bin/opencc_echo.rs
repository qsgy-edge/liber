//! THROWAWAY helper: convert stdin lines with one OpenCC built-in config.
//! Usage: opencc_echo <t2s|tw2s|tw2sp|s2t|s2tw|s2twp>
use std::io::{self, BufRead, Write};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let name = args.get(1).cloned().unwrap_or_else(|| "t2s".into());
    let config = match name.as_str() {
        "t2s" => ferrous_opencc::config::BuiltinConfig::T2s,
        "tw2s" => ferrous_opencc::config::BuiltinConfig::Tw2s,
        "tw2sp" => ferrous_opencc::config::BuiltinConfig::Tw2sp,
        "s2t" => ferrous_opencc::config::BuiltinConfig::S2t,
        "s2tw" => ferrous_opencc::config::BuiltinConfig::S2tw,
        "s2twp" => ferrous_opencc::config::BuiltinConfig::S2twp,
        other => panic!("unknown config {other}"),
    };
    let converter = ferrous_opencc::OpenCC::from_config(config).unwrap();
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        writeln!(stdout, "{}", converter.convert(&line)).unwrap();
    }
}
