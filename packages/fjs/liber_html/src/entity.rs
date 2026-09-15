//! The frozen `AnalyzeRule.getString` entity step.
//!
//! The frozen reader runs every `getString` result through
//! `StringEscapeUtils.unescapeHtml4`, including results that already came out of
//! jsoup (so a serialized `&amp;` is decoded again, and a double-encoded
//! `&amp;amp;` in the source ends up as `&`).

use markup5ever::data::NAMED_ENTITIES;

/// Decodes HTML character references the way the frozen reader's helper does.
///
/// Two differences from the Java helper are deliberate and recorded in the
/// capability matrix: the named-entity table is HTML5's set (a superset of
/// HTML 4's, so an entity Java leaves alone can be substituted here), and
/// numeric references accept any valid scalar value instead of Java's
/// invalid-reference placeholder mapping.
pub fn unescape_html(value: &str) -> String {
    if !value.contains('&') {
        return value.to_string();
    }
    let chars: Vec<char> = value.chars().collect();
    let mut out = String::new();
    let mut index = 0;
    while index < chars.len() {
        if chars[index] != '&' {
            out.push(chars[index]);
            index += 1;
            continue;
        }
        if let Some(end) = numeric_reference(&chars, index) {
            out.push(end.0);
            index = end.1;
            continue;
        }
        if let Some(end) = named_reference(&chars, index) {
            out.push(end.0);
            index = end.1;
            continue;
        }
        out.push('&');
        index += 1;
    }
    out
}

/// `&#123;` or `&#x1f;`, requiring the closing semicolon.
fn numeric_reference(chars: &[char], start: usize) -> Option<(char, usize)> {
    if chars.get(start + 1) != Some(&'#') {
        return None;
    }
    let (radix, mut index) = match chars.get(start + 2) {
        Some('x') | Some('X') => (16, start + 3),
        _ => (10, start + 2),
    };
    let digits_start = index;
    while index < chars.len() && index - digits_start < 8 {
        let c = chars[index];
        let digit = if radix == 16 { c.is_ascii_hexdigit() } else { c.is_ascii_digit() };
        if !digit {
            break;
        }
        index += 1;
    }
    if index == digits_start || chars.get(index) != Some(&';') {
        return None;
    }
    let digits: String = chars[digits_start..index].iter().collect();
    let code = i64::from_str_radix(&digits, radix).ok()?;
    let value = char::from_u32(u32::try_from(code).ok()?)?;
    Some((value, index + 1))
}

/// `&name;` from the HTML5 table, requiring the closing semicolon.
fn named_reference(chars: &[char], start: usize) -> Option<(char, usize)> {
    let mut index = start + 1;
    let mut name = String::new();
    while index < chars.len() && chars[index].is_ascii_alphanumeric() {
        name.push(chars[index]);
        index += 1;
    }
    if name.is_empty() || chars.get(index) != Some(&';') {
        return None;
    }
    name.push(';');
    let (code, extra) = *NAMED_ENTITIES.get(name.as_str())?;
    if extra != 0 {
        // Multi-code-point entities stay as written: they do not appear in
        // Book Source text, and Java's HTML 4 table has no equivalent.
        return None;
    }
    Some((char::from_u32(code)?, index + 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_named_and_numeric_references() {
        assert_eq!(unescape_html("a&amp;b"), "a&b");
        assert_eq!(unescape_html("&lt;div&gt;"), "<div>");
        assert_eq!(unescape_html("&#20320;&#22909;"), "你好");
        assert_eq!(unescape_html("&#x4f60;"), "你");
    }

    #[test]
    fn leaves_unknown_and_bare_ampersands_alone() {
        assert_eq!(unescape_html("a & b"), "a & b");
        assert_eq!(unescape_html("&notanentity;"), "&notanentity;");
        assert_eq!(unescape_html("&#zz;"), "&#zz;");
        assert_eq!(unescape_html("100% &copy"), "100% &copy");
    }
}
