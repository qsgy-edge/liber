//! A BOM probe must not consume the start of a BOM-less window.
use liber_text::read_window;

fn check(name: &str, text: &str) {
    let directory =
        std::env::temp_dir().join(format!("liber-text-zero-{}-{name}", std::process::id()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("book.txt");
    std::fs::write(&path, text).unwrap();
    let window = read_window(&path, "UTF-8", None, 0, 5, 1024).unwrap();
    // Remove scratch before asserting so a failing baseline remains repeatable.
    std::fs::remove_dir_all(directory).unwrap();
    assert_eq!(window.text, text.chars().take(5).collect::<String>());
    assert_eq!(window.byte_offset, 0);
    assert_eq!(window.code_unit_offset, 0);
}

#[test]
fn no_anchor_at_zero_preserves_ascii_prefix() {
    check("ascii", "ABCDE正文\n下一行\n");
}

#[test]
fn no_anchor_at_zero_preserves_multibyte_prefix() {
    check("multibyte", "第一章正文\n下一行\n");
}
