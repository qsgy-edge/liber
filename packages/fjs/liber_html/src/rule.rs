//! Legado's rule layer over the jsoup-compatible DOM.
//!
//! Ported from the frozen `AnalyzeByJSoup.kt` (rule modes, `@` chains, `&&`/`||`/
//! `%%` merges, the `ElementsSingle` index syntax, and `getResultLast`'s
//! extraction switch) and `AnalyzeRule.kt`'s `SourceRule` (`##` replacement and
//! the mode prefixes). Rule families that belong to other tickets - rule-level
//! JavaScript and templates, XPath, JSON, regex captures - fail loudly instead
//! of returning approximated values.

use crate::dom::{Dom, NodeId, NodeKind};
use crate::selector::{self, Evaluator};
use crate::serialize;
use fancy_regex::Regex;

#[derive(Debug, Clone, PartialEq)]
pub enum RuleErrorKind {
    /// A rule family this adapter deliberately does not implement.
    Unsupported,
    /// A rule that cannot be parsed at all.
    Parse,
    /// A rule that parsed but cannot be evaluated against this document.
    Runtime,
}

#[derive(Debug, Clone)]
pub struct RuleError {
    pub kind: RuleErrorKind,
    pub message: String,
}

impl RuleError {
    pub fn unsupported(message: impl Into<String>) -> RuleError {
        RuleError { kind: RuleErrorKind::Unsupported, message: message.into() }
    }
    pub fn parse(message: impl Into<String>) -> RuleError {
        RuleError { kind: RuleErrorKind::Parse, message: message.into() }
    }
    pub fn runtime(message: impl Into<String>) -> RuleError {
        RuleError { kind: RuleErrorKind::Runtime, message: message.into() }
    }
}

impl From<selector::SelectError> for RuleError {
    fn from(error: selector::SelectError) -> RuleError {
        RuleError::unsupported(format!("不支持的 CSS 选择器：{}", error.message))
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Mode {
    Default,
    Css,
}

#[derive(Debug, Clone)]
pub struct Replace {
    pub regex: String,
    pub replacement: String,
    pub replace_first: bool,
}

/// Frozen `AnalyzeRule.SourceRule` reduced to the HTML path: mode detection,
/// `@@` escaping, and the `##` replacement fields.
#[derive(Debug, Clone)]
pub struct SourceRule {
    pub mode: Mode,
    pub rule: String,
    pub replace: Option<Replace>,
}

impl SourceRule {
    pub fn parse(raw: &str) -> Result<SourceRule, RuleError> {
        let trimmed = raw.trim();
        let lower = trimmed.to_lowercase();
        let mode;
        let body;
        if let Some(rest) = lower.strip_prefix("@css:").map(|_| &trimmed[5..]) {
            mode = Mode::Css;
            body = rest.trim().to_string();
        } else if let Some(rest) = trimmed.strip_prefix("@@") {
            mode = Mode::Default;
            body = rest.to_string();
        } else if lower.starts_with("@xpath:") || trimmed.starts_with('/') {
            return Err(RuleError::unsupported("暂不支持 XPath 规则"));
        } else if lower.starts_with("@json:") || trimmed.starts_with("$.") || trimmed.starts_with("$[") {
            return Err(RuleError::unsupported("暂不支持 JSON 规则解析"));
        } else if lower.starts_with("@js:") || lower.starts_with("<js>") {
            return Err(RuleError::unsupported("暂不支持该元素规则"));
        } else {
            mode = Mode::Default;
            body = trimmed.to_string();
        }
        reject_unsupported_rule_body(&body)?;
        let (rule, replace) = split_replace(&body);
        Ok(SourceRule { mode, rule, replace })
    }
}

fn reject_unsupported_rule_body(body: &str) -> Result<(), RuleError> {
    let lower = body.to_lowercase();
    if lower.contains("@js:") || lower.contains("<js>") {
        return Err(RuleError::unsupported("暂不支持该元素规则"));
    }
    if body.contains("{{") || lower.contains("@get:") {
        return Err(RuleError::unsupported("暂不支持该元素规则"));
    }
    if lower.contains("@xpath:") || lower.contains("@json:") {
        return Err(RuleError::unsupported("暂不支持该元素规则"));
    }
    if has_regex_capture(body) {
        return Err(RuleError::unsupported("暂不支持该替换形式"));
    }
    Ok(())
}

/// `$1`-style captures in rule text belong to the rule-JavaScript ticket.
fn has_regex_capture(body: &str) -> bool {
    let chars: Vec<char> = body.chars().collect();
    index_of_capture(&chars).is_some()
}

fn index_of_capture(chars: &[char]) -> Option<usize> {
    for (index, c) in chars.iter().enumerate() {
        if *c == '$' && chars.get(index + 1).map(|next| next.is_ascii_digit()).unwrap_or(false) {
            return Some(index);
        }
    }
    None
}

/// Splits `##` fields the way `SourceRule.makeUpRule` does.
fn split_replace(body: &str) -> (String, Option<Replace>) {
    let parts: Vec<&str> = body.split("##").collect();
    let rule = parts[0].trim().to_string();
    if parts.len() < 2 {
        return (rule, None);
    }
    let replace = Replace {
        regex: parts[1].to_string(),
        replacement: if parts.len() > 2 { parts[2].to_string() } else { String::new() },
        replace_first: parts.len() > 3,
    };
    (rule, Some(replace))
}

/// Frozen `AnalyzeRule.replaceRegex`.
pub fn apply_replace(value: &str, replace: &Replace) -> String {
    let compiled = Regex::new(&replace.regex).ok();
    if replace.replace_first {
        return match compiled {
            Some(regex) => match regex.find(value) {
                Ok(Some(found)) => {
                    let text = found.as_str().to_string();
                    regex.replace_all(&text, replace.replacement.as_str()).into_owned()
                }
                _ => String::new(),
            },
            None => value.replacen(&replace.regex, &replace.replacement, 1),
        };
    }
    match compiled {
        Some(regex) => regex.replace_all(value, replace.replacement.as_str()).into_owned(),
        None => value.replace(&replace.regex, &replace.replacement),
    }
}

/// Frozen `RuleAnalyzer.trim`: drop leading `@`s and whitespace.
fn trim_leading(rule: &str) -> String {
    rule.trim_start_matches(|c: char| c == '@' || c < '!').to_string()
}

/// Splits a rule on the given separators at bracket depth zero, which is what
/// the frozen `RuleAnalyzer.splitRule` computes: a separator inside `[...]` or
/// `(...)` - including quoted values - belongs to the selector.
fn split_rule(rule: &str, separators: &[&str]) -> Vec<String> {
    let chars: Vec<char> = rule.chars().collect();
    let mut parts: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    let mut index = 0;
    while index < chars.len() {
        let c = chars[index];
        if let Some(active) = quote {
            current.push(c);
            if c == active {
                quote = None;
            }
            index += 1;
            continue;
        }
        if depth > 0 && (c == '\'' || c == '"') {
            quote = Some(c);
            current.push(c);
            index += 1;
            continue;
        }
        if c == '[' || c == '(' || c == '{' {
            depth += 1;
            current.push(c);
            index += 1;
            continue;
        }
        if c == ']' || c == ')' || c == '}' {
            depth -= 1;
            current.push(c);
            index += 1;
            continue;
        }
        if depth == 0 {
            let rest: String = chars[index..].iter().collect();
            if let Some(separator) = separators.iter().find(|separator| rest.starts_with(**separator)) {
                parts.push(current.trim().to_string());
                current = String::new();
                index += separator.chars().count();
                continue;
            }
        }
        current.push(c);
        index += 1;
    }
    parts.push(current.trim().to_string());
    parts
}

/// Frozen `RuleAnalyzer.splitRule("&&", "||", "%%")`: the found separator is
/// the first one to appear, and only that separator splits the rest of the rule.
fn split_merge(rule: &str) -> (Vec<String>, Option<String>) {
    let chars: Vec<char> = rule.chars().collect();
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    let mut operator: Option<&str> = None;
    let mut index = 0;
    'outer: while index < chars.len() {
        let c = chars[index];
        if let Some(active) = quote {
            if c == active {
                quote = None;
            }
            index += 1;
            continue;
        }
        if depth > 0 && (c == '\'' || c == '"') {
            quote = Some(c);
            index += 1;
            continue;
        }
        match c {
            '[' | '(' | '{' => {
                depth += 1;
                index += 1;
                continue;
            }
            ']' | ')' | '}' => {
                depth -= 1;
                index += 1;
                continue;
            }
            _ => {}
        }
        if depth == 0 {
            let rest: String = chars[index..].iter().collect();
            for separator in ["&&", "||", "%%"] {
                if rest.starts_with(separator) {
                    operator = Some(separator);
                    break 'outer;
                }
            }
        }
        index += 1;
    }
    match operator {
        Some(separator) => {
            let parts = split_rule(rule, &[separator]);
            (parts, Some(separator.to_string()))
        }
        None => (vec![rule.trim().to_string()], None),
    }
}

fn merge_values(results: &[Vec<String>], merge: Option<&str>) -> Vec<String> {
    if results.is_empty() {
        return Vec::new();
    }
    match merge {
        Some("%%") => {
            let mut out = Vec::new();
            for index in 0..results[0].len() {
                for result in results {
                    if index < result.len() {
                        out.push(result[index].clone());
                    }
                }
            }
            out
        }
        _ => results.iter().flatten().cloned().collect(),
    }
}

fn merge_elements(results: &[Vec<NodeId>], merge: Option<&str>) -> Vec<NodeId> {
    if results.is_empty() {
        return Vec::new();
    }
    match merge {
        Some("%%") => {
            let mut out = Vec::new();
            for index in 0..results[0].len() {
                for result in results {
                    if index < result.len() {
                        out.push(result[index]);
                    }
                }
            }
            out
        }
        _ => results.iter().flatten().copied().collect(),
    }
}

#[derive(Debug, Clone, PartialEq)]
enum IndexItem {
    Single(i64),
    Range { start: Option<i64>, end: Option<i64>, step: i64 },
}

#[derive(Debug, Clone)]
struct IndexSpec {
    split: char,
    before_rule: String,
    index_default: Vec<i64>,
    indexes: Vec<IndexItem>,
}

/// Port of the frozen `ElementsSingle.findIndexSet`.
#[allow(unused_assignments)]
fn find_indexes(rule: &str) -> Result<IndexSpec, RuleError> {
    let rus: Vec<char> = rule.trim().chars().collect();
    // The frozen `ElementsSingle.split` defaults to the selecting '.', and only
    // a rule with no index at all falls through to the no-filter ' ' case.
    let mut split = '.';
    let mut before_rule = String::new();
    let mut index_default: Vec<i64> = Vec::new();
    let mut indexes: Vec<IndexItem> = Vec::new();
    let mut len: i64 = rus.len() as i64;
    let head = rus.last() == Some(&']');

    if head {
        len -= 1;
        let mut digits = String::new();
        let mut minus = false;
        let mut cur_list: Vec<Option<i64>> = Vec::new();
        while {
            len -= 1;
            len >= 0
        } {
            let rl = rus[len as usize];
            if rl == ' ' {
                continue;
            }
            if rl.is_ascii_digit() {
                digits.insert(0, rl);
                continue;
            }
            if rl == '-' {
                minus = true;
                continue;
            }
            let cur_int = if digits.is_empty() {
                None
            } else {
                let value = digits.parse::<i64>().map_err(|_| RuleError::parse("索引格式错误"))?;
                Some(if minus { -value } else { value })
            };
            if rl == ':' {
                cur_list.push(cur_int);
            } else {
                match cur_int {
                    None => {
                        // Not an index list: the bracket belongs to a CSS selector.
                        return Ok(IndexSpec { split: ' ', before_rule: rus.iter().collect(), index_default, indexes });
                    }
                    Some(value) => {
                        if cur_list.is_empty() {
                            indexes.push(IndexItem::Single(value));
                        } else {
                            let step = if cur_list.len() == 2 { cur_list[0].unwrap_or(1) } else { 1 };
                            indexes.push(IndexItem::Range {
                                start: Some(value),
                                end: cur_list[cur_list.len() - 1],
                                step,
                            });
                            cur_list.clear();
                        }
                    }
                }
                let mut marker = rl;
                if marker == '!' {
                    split = '!';
                    loop {
                        len -= 1;
                        marker = if len >= 0 { rus[len as usize] } else { '\0' };
                        if !(len > 0 && marker == ' ') {
                            break;
                        }
                    }
                }
                if marker == '[' {
                    before_rule = rus[..len.max(0) as usize].iter().collect();
                    return Ok(IndexSpec { split, before_rule, index_default, indexes });
                }
                if marker != ',' {
                    break;
                }
            }
            digits = String::new();
            minus = false;
        }
    } else {
        let mut digits = String::new();
        let mut minus = false;
        while {
            len -= 1;
            len >= 0
        } {
            let rl = rus[len as usize];
            if rl == ' ' {
                continue;
            }
            if rl.is_ascii_digit() {
                digits.insert(0, rl);
                continue;
            }
            if rl == '-' {
                minus = true;
                continue;
            }
            if rl == '!' || rl == '.' || rl == ':' {
                if digits.is_empty() {
                    break;
                }
                let value = digits.parse::<i64>().map_err(|_| RuleError::parse("索引格式错误"))?;
                index_default.push(if minus { -value } else { value });
                if rl != ':' {
                    split = rl;
                    before_rule = rus[..len.max(0) as usize].iter().collect();
                    return Ok(IndexSpec { split, before_rule, index_default, indexes });
                }
            } else {
                break;
            }
            digits = String::new();
            minus = false;
        }
    }

    Ok(IndexSpec { split: ' ', before_rule: rus.iter().collect(), index_default, indexes })
}

/// Port of `ElementsSingle.getElementsSingle`.
pub fn elements_single(dom: &Dom, context: NodeId, rule: &str) -> Result<Vec<NodeId>, RuleError> {
    let spec = find_indexes(rule)?;
    let mut elements: Vec<NodeId> = if spec.before_rule.is_empty() {
        dom.element_children(context)
    } else {
        let rules: Vec<&str> = spec.before_rule.split('.').collect();
        match rules[0] {
            "children" => dom.element_children(context),
            "class" => selector::collect(dom, context, &Evaluator::Class(argument(rules.get(1)))),
            "tag" => selector::collect(dom, context, &Evaluator::Tag(normalize(argument(rules.get(1))))),
            "id" => selector::collect(dom, context, &Evaluator::Id(argument(rules.get(1)))),
            "text" => selector::collect(dom, context, &Evaluator::ContainsOwnText(argument(rules.get(1)))),
            _ => selector::select(dom, context, &spec.before_rule)?,
        }
    };

    if spec.split == ' ' {
        return Ok(elements);
    }

    let len = elements.len() as i64;
    let mut selected: Vec<i64> = Vec::new();
    let last = if !spec.index_default.is_empty() {
        spec.index_default.len() as i64 - 1
    } else {
        spec.indexes.len() as i64 - 1
    };
    if spec.indexes.is_empty() {
        let mut index = last;
        while index >= 0 {
            let value = spec.index_default[index as usize];
            if value >= 0 && value < len {
                if !selected.contains(&value) {
                    selected.push(value);
                }
            } else if value < 0 && len >= -value {
                let resolved = value + len;
                if !selected.contains(&resolved) {
                    selected.push(resolved);
                }
            }
            index -= 1;
        }
    } else {
        let mut index = last;
        while index >= 0 {
            match &spec.indexes[index as usize] {
                IndexItem::Single(value) => {
                    if *value >= 0 && *value < len {
                        if !selected.contains(value) {
                            selected.push(*value);
                        }
                    } else if *value < 0 && len >= -*value {
                        let resolved = value + len;
                        if !selected.contains(&resolved) {
                            selected.push(resolved);
                        }
                    }
                }
                IndexItem::Range { start, end, step } => {
                    let mut start = start.unwrap_or(0);
                    if start < 0 {
                        start += len;
                    }
                    let mut end = end.unwrap_or(len - 1);
                    if end < 0 {
                        end += len;
                    }
                    if (start < 0 && end < 0) || (start >= len && end >= len) {
                        index -= 1;
                        continue;
                    }
                    start = start.clamp(0, len - 1);
                    end = end.clamp(0, len - 1);
                    if start == end || *step >= len {
                        if !selected.contains(&start) {
                            selected.push(start);
                        }
                        index -= 1;
                        continue;
                    }
                    let step = if *step > 0 {
                        *step
                    } else if -*step < len {
                        *step + len
                    } else {
                        1
                    };
                    if end > start {
                        let step = step.max(1);
                        let mut value = start;
                        while value <= end {
                            if !selected.contains(&value) {
                                selected.push(value);
                            }
                            value += step;
                        }
                    } else {
                        let step = -step.max(1);
                        let mut value = start;
                        while value >= end {
                            if !selected.contains(&value) {
                                selected.push(value);
                            }
                            value += step;
                        }
                    }
                }
            }
            index -= 1;
        }
    }

    if spec.split == '!' {
        elements = elements
            .into_iter()
            .enumerate()
            .filter(|(index, _)| !selected.contains(&(*index as i64)))
            .map(|(_, element)| element)
            .collect();
    } else if spec.split == '.' {
        elements = selected.iter().map(|index| elements[*index as usize]).collect();
    }
    Ok(elements)
}

fn argument(value: Option<&&str>) -> String {
    value.map(|value| value.to_string()).unwrap_or_default()
}

fn normalize(value: String) -> String {
    value.trim().to_lowercase()
}

/// Frozen `AnalyzeByJSoup.getElements`.
pub fn elements(dom: &Dom, context: NodeId, rule: &str) -> Result<Vec<NodeId>, RuleError> {
    if rule.is_empty() {
        return Ok(Vec::new());
    }
    let source = SourceRule::parse(rule)?;
    let (parts, merge) = split_merge(&source.rule);
    let mut results: Vec<Vec<NodeId>> = Vec::new();
    if source.mode == Mode::Css {
        for part in &parts {
            let found = selector::select(dom, context, part)?;
            let non_empty = !found.is_empty();
            results.push(found);
            if non_empty && merge.as_deref() == Some("||") {
                break;
            }
        }
    } else {
        for part in &parts {
            let trimmed = trim_leading(part);
            let chain = split_rule(&trimmed, &["@"]);
            let found = if chain.len() > 1 {
                let mut current = vec![context];
                for step in &chain {
                    let mut next = Vec::new();
                    for element in &current {
                        next.extend(elements(dom, *element, step)?);
                    }
                    current = next;
                }
                current
            } else {
                elements_single(dom, context, &trimmed)?
            };
            let non_empty = !found.is_empty();
            results.push(found);
            if non_empty && merge.as_deref() == Some("||") {
                break;
            }
        }
    }
    Ok(merge_elements(&results, merge.as_deref()))
}

/// Frozen `AnalyzeByJSoup.getResultLast`.
fn result_last(dom: &Dom, elements: &[NodeId], last_rule: &str) -> Result<Vec<String>, RuleError> {
    let mut out: Vec<String> = Vec::new();
    match last_rule {
        "text" => {
            for element in elements {
                let text = dom.text(*element);
                if !text.is_empty() {
                    out.push(text);
                }
            }
        }
        "textNodes" => {
            for element in elements {
                let mut nodes: Vec<String> = Vec::new();
                for child in dom.children(*element) {
                    if let NodeKind::Text { text } = dom.kind(*child) {
                        let trimmed = text.trim_matches(|c: char| c <= ' ');
                        if !trimmed.is_empty() {
                            nodes.push(trimmed.to_string());
                        }
                    }
                }
                if !nodes.is_empty() {
                    out.push(nodes.join("\n"));
                }
            }
        }
        "ownText" => {
            for element in elements {
                let text = dom.own_text(*element);
                if !text.is_empty() {
                    out.push(text);
                }
            }
        }
        "html" => {
            let html = serialize::elements_outer_html(dom, elements, true);
            if !html.is_empty() {
                out.push(html);
            }
        }
        "all" => out.push(serialize::elements_outer_html(dom, elements, true)),
        attribute => {
            for element in elements {
                let Some(value) = dom.attr(*element, attribute) else { continue };
                if value.trim().is_empty() || out.iter().any(|existing| existing == value) {
                    continue;
                }
                out.push(value.to_string());
            }
        }
    }
    Ok(out)
}

/// Frozen `AnalyzeByJSoup.getResultList`.
fn result_list(dom: &Dom, context: NodeId, rule: &str) -> Result<Vec<String>, RuleError> {
    if rule.is_empty() {
        return Ok(Vec::new());
    }
    let mut elements = vec![context];
    let trimmed = trim_leading(rule);
    let chain = split_rule(&trimmed, &["@"]);
    let last = chain.len() - 1;
    for step in &chain[..last] {
        let mut next = Vec::new();
        for element in &elements {
            next.extend(elements_single(dom, *element, step)?);
        }
        elements = next;
    }
    if elements.is_empty() {
        return Ok(Vec::new());
    }
    result_last(dom, &elements, &chain[last])
}

/// Frozen `AnalyzeByJSoup.getStringList`.
pub fn string_list(dom: &Dom, context: NodeId, rule: &str) -> Result<Vec<String>, RuleError> {
    if rule.is_empty() {
        return Ok(Vec::new());
    }
    let source = SourceRule::parse(rule)?;
    if source.rule.is_empty() {
        return Ok(vec![dom.data(context)]);
    }
    let (parts, merge) = split_merge(&source.rule);
    let mut results: Vec<Vec<String>> = Vec::new();
    for part in &parts {
        let values = if source.mode == Mode::Css {
            let Some(last_index) = part.rfind('@') else {
                return Err(RuleError::unsupported("CSS 规则缺少提取方式"));
            };
            let elements = selector::select(dom, context, &part[..last_index])?;
            result_last(dom, &elements, &part[last_index + 1..])?
        } else {
            result_list(dom, context, part)?
        };
        if !values.is_empty() {
            results.push(values);
            if merge.as_deref() == Some("||") {
                break;
            }
        }
    }
    Ok(merge_values(&results, merge.as_deref()))
}

/// Frozen `AnalyzeByJSoup.getString`, i.e. the value one rule yields for one
/// context, with the `##` replacement applied to the joined result.
pub fn string(dom: &Dom, context: NodeId, rule: &str) -> Result<String, RuleError> {
    let source = SourceRule::parse(rule)?;
    let values = string_list(dom, context, rule)?;
    let joined = match values.len() {
        0 => String::new(),
        1 => values[0].clone(),
        _ => values.join("\n"),
    };
    Ok(match &source.replace {
        Some(replace) => apply_replace(&joined, replace),
        None => joined,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOC: &str = r#"
        <div class="info"><span>A</span><span>B</span><span>C</span><span>D</span></div>
        <ul class="chapters"><li><a href="/ad">忽略</a></li><li><a href="/1">第一章</a></li></ul>
        <div class="chapter_content">第一段<br>第二段<span>嵌套广告</span><br>第三段</div>
        <a href="/2">下一页</a>
        <div id="meta" data-id="42">作者：忘语</div>
    "#;

    fn text(rule: &str) -> String {
        let dom = Dom::parse(DOC);
        string(&dom, 0, rule).expect("rule evaluates")
    }

    fn list(rule: &str) -> Vec<String> {
        let dom = Dom::parse(DOC);
        string_list(&dom, 0, rule).expect("rule evaluates")
    }

    #[test]
    fn legacy_ordered_indices_and_chains() {
        assert_eq!(text(".info span.1:3:0@text"), "B\nD\nA");
        assert_eq!(list(".chapters li!0@a@href"), vec!["/1"]);
        assert_eq!(list(".chapters li[0]@a@href"), vec!["/ad"]);
        assert_eq!(list(".chapters li[1,0]@a@href"), vec!["/1", "/ad"]);
        assert_eq!(text(".info span.-1@text"), "D");
        assert_eq!(text(".info span@textNodes"), "A\nB\nC\nD");
        assert_eq!(list("text.下一页@href"), vec!["/2"]);
        assert_eq!(text(".chapter_content@textNodes"), "第一段\n第二段\n第三段");
    }

    #[test]
    fn extraction_operations() {
        assert_eq!(text(".chapter_content@text"), "第一段 第二段嵌套广告 第三段");
        assert_eq!(text(".chapter_content@ownText"), "第一段 第二段 第三段");
        assert_eq!(list(".chapters li@a@html"), vec!["<a href=\"/ad\">忽略</a>
<a href=\"/1\">第一章</a>"]);
        assert_eq!(list("#meta@data-id"), vec!["42"]);
        assert_eq!(list(".chapters a@href"), vec!["/ad", "/1"]);
        assert_eq!(text("#meta@text##^作者：##"), "忘语");
    }

    #[test]
    fn merge_operators() {
        assert_eq!(list(".info span@text||#meta@data-id"), vec!["A", "B", "C", "D"]);
        assert_eq!(list("#nothing@text||#meta@data-id"), vec!["42"]);
        assert_eq!(list(".info span@text&&#meta@data-id"), vec!["A", "B", "C", "D", "42"]);
        assert_eq!(
            list(".info span.0:1@text%%#meta@data-id"),
            vec!["A", "42", "B"]
        );
    }

    #[test]
    fn legacy_sub_syntax() {
        assert_eq!(list("class.info@text"), vec!["ABCD"]);
        assert_eq!(text("tag.span@text"), "A
B
C
D
嵌套广告");
        assert_eq!(text("id.meta@text"), "作者：忘语");
        // `children` on the document context is the `<html>` element, as frozen, and
        // the whole-document text shows jsoup's block spacing.
        assert_eq!(text("children.0@text"), "ABCD 忽略 第一章 第一段 第二段嵌套广告 第三段 下一页 作者：忘语");
    }

    #[test]
    fn css_mode_rules() {
        assert_eq!(text("@CSS:.info span@text"), "A
B
C
D");
        assert_eq!(list("@CSS:div#meta@data-id"), vec!["42"]);
        assert_eq!(list("@CSS:ul.chapters li:first-child a@href"), vec!["/ad"]);
        assert_eq!(text("@CSS:.chapters li:nth-child(2) a@text"), "第一章");
    }

    #[test]
    fn unsupported_rule_families_fail_loudly() {
        let dom = Dom::parse(DOC);
        for rule in [
            "div@js:result",
            "div@XPath://a",
            "@Json:$.a",
            "div@href$1",
            "div{{page}}",
        ] {
            let error = string(&dom, 0, rule).expect_err(rule);
            assert_eq!(error.kind, RuleErrorKind::Unsupported, "{}", rule);
        }
    }
}
