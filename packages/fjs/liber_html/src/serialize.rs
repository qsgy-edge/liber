//! jsoup HTML serialization (`Element.outerHtml`) with jsoup's default output
//! settings: pretty printing on, indent amount 1, `base` escape mode.
//!
//! The frozen `html`/`all` extractions return `Elements.outerHtml()`, so the
//! whitespace this module emits is part of the compared output.

use crate::dom::{Dom, NodeId, NodeKind, format_as_block, is_block, is_empty_tag, is_whitespace, last_char_is_whitespace};

pub fn outer_html(dom: &Dom, id: NodeId) -> String {
    outer_html_with(dom, id, false)
}

/// `skip_scripts` reproduces the frozen `html` extraction, which drops every
/// descendant `script` and `style` element before serializing.
pub fn outer_html_with(dom: &Dom, id: NodeId, skip_scripts: bool) -> String {
    let mut accum = String::new();
    outer_html_into(dom, id, 0, skip_scripts, &mut accum);
    accum
}

/// jsoup `Elements.outerHtml`: elements joined with a newline.
pub fn elements_outer_html(dom: &Dom, ids: &[NodeId], skip_scripts: bool) -> String {
    ids.iter().map(|id| outer_html_with(dom, *id, skip_scripts)).collect::<Vec<_>>().join("\n")
}

fn outer_html_into(dom: &Dom, id: NodeId, depth: usize, skip_scripts: bool, accum: &mut String) {
    if skip_scripts {
        if let Some(name) = dom.element_name(id) {
            if name == "script" || name == "style" {
                return;
            }
        }
    }
    match dom.kind(id) {
        NodeKind::Document => {
            for child in dom.children(id).to_vec() {
                outer_html_into(dom, child, depth, skip_scripts, accum);
            }
        }
        NodeKind::Doctype { name } => {
            if node_sibling_index(dom, id) > 0 {
                accum.push('\n');
            }
            accum.push_str("<!doctype ");
            accum.push_str(&name.to_ascii_lowercase());
            accum.push('>');
        }
        NodeKind::Comment { text } => {
            if comment_indents(dom, id) {
                indent(accum, depth);
            }
            accum.push_str("<!--");
            accum.push_str(text);
            accum.push_str("-->");
        }
        NodeKind::Text { text } => text_html(dom, id, text, depth, accum),
        NodeKind::Data { text } => accum.push_str(text),
        NodeKind::Element { name, .. } => element_html(dom, id, name, depth, skip_scripts, accum),
    }
}

fn element_html(dom: &Dom, id: NodeId, name: &str, depth: usize, skip_scripts: bool, accum: &mut String) {
    if should_indent(dom, id) && !accum.is_empty() {
        indent(accum, depth);
    }
    accum.push('<');
    accum.push_str(name);
    attributes_html(dom, id, accum);
    let children = dom.children(id).to_vec();
    if children.is_empty() && is_empty_tag(name) {
        accum.push('>');
        return;
    }
    accum.push('>');
    for child in children.iter() {
        outer_html_into(dom, *child, depth + 1, skip_scripts, accum);
    }
    if !children.is_empty()
        && format_as_block(name)
        && !dom.preserve_whitespace(dom.parent(id))
    {
        indent(accum, depth);
    }
    accum.push_str("</");
    accum.push_str(name);
    accum.push('>');
}

fn text_html(dom: &Dom, id: NodeId, text: &str, depth: usize, accum: &mut String) {
    let parent = dom.parent(id);
    let normalise_white = !dom.preserve_whitespace(parent);
    let trim_like_block = parent
        .map(|parent_id| {
            let parent_name = dom.element_name(parent_id).unwrap_or("");
            is_block(parent_name) || format_as_block(parent_name)
        })
        .unwrap_or(false);
    let sibling_index = node_sibling_index(dom, id);
    let mut trim_leading = false;
    let mut trim_trailing = false;
    if normalise_white {
        trim_leading = (trim_like_block && sibling_index == 0)
            || dom.parent(id).map(|parent_id| matches!(dom.kind(parent_id), NodeKind::Document)).unwrap_or(false);
        trim_trailing = trim_like_block && dom.next_sibling(id).is_none();
        let next = dom.next_sibling(id);
        let previous = dom.previous_sibling(id);
        let is_blank = text.chars().all(is_whitespace);
        let could_skip = next
            .map(|next_id| {
                (dom.is_element(next_id) && should_indent(dom, next_id))
                    || (matches!(dom.kind(next_id), NodeKind::Text { .. }) && dom.text_is_blank(next_id))
            })
            .unwrap_or(false)
            || previous
                .map(|previous_id| {
                    dom.element_name(previous_id)
                        .map(|name| is_block(name) || name == "br")
                        .unwrap_or(false)
                })
                .unwrap_or(false);
        if could_skip && is_blank {
            return;
        }
        let parent_format_as_block = parent
            .map(|parent_id| format_as_block(dom.element_name(parent_id).unwrap_or("")))
            .unwrap_or(false);
        let previous_is_br = previous.map(|previous_id| dom.is_tag(previous_id, "br")).unwrap_or(false);
        if (sibling_index == 0 && parent.is_some() && parent_format_as_block && !is_blank)
            || (sibling_index > 0 && previous_is_br)
        {
            indent(accum, depth);
        }
    }
    escape(accum, text, false, normalise_white, trim_leading, trim_trailing);
}

fn attributes_html(dom: &Dom, id: NodeId, accum: &mut String) {
    for (key, value) in dom.attributes(id) {
        accum.push(' ');
        accum.push_str(key);
        let collapse = (value.is_empty() || value.eq_ignore_ascii_case(key))
            && is_boolean_attribute(key);
        if !collapse {
            accum.push_str("=\"");
            escape(accum, value, true, false, false, false);
            accum.push('"');
        }
    }
}

/// jsoup `Element.shouldIndent` (`outline` is off in this product).
fn should_indent(dom: &Dom, id: NodeId) -> bool {
    let Some(name) = dom.element_name(id) else { return false };
    let parent = dom.parent(id);
    let format_as_block_here = format_as_block(name)
        || parent
            .map(|parent_id| format_as_block(dom.element_name(parent_id).unwrap_or("")))
            .unwrap_or(false);
    if !format_as_block_here {
        return false;
    }
    let inlineable = !is_block(name)
        && parent
            .map(|parent_id| {
                dom.element_name(parent_id).map(is_block).unwrap_or(false)
            })
            .unwrap_or(true)
        && !is_effectively_first(dom, id)
        && name != "br";
    !inlineable && !dom.preserve_whitespace(parent)
}

fn comment_indents(dom: &Dom, id: NodeId) -> bool {
    let effectively_first = is_effectively_first(dom, id);
    let parent_block = dom
        .parent(id)
        .map(|parent_id| format_as_block(dom.element_name(parent_id).unwrap_or("")))
        .unwrap_or(false);
    effectively_first && parent_block
}

/// jsoup `Node.isEffectivelyFirst`.
fn is_effectively_first(dom: &Dom, id: NodeId) -> bool {
    match node_sibling_index(dom, id) {
        0 => true,
        1 => dom
            .previous_sibling(id)
            .map(|previous| matches!(dom.kind(previous), NodeKind::Text { .. }) && dom.text_is_blank(previous))
            .unwrap_or(false),
        _ => false,
    }
}

fn node_sibling_index(dom: &Dom, id: NodeId) -> usize {
    let Some(parent) = dom.parent(id) else { return 0 };
    dom.children(parent).iter().position(|child| *child == id).unwrap_or(0)
}

fn indent(accum: &mut String, depth: usize) {
    if !accum.is_empty() {
        accum.push('\n');
    }
    for _ in 0..depth {
        accum.push(' ');
    }
}

/// jsoup `Entities.escape` in the default `base` escape mode over UTF-8.
pub fn escape(
    accum: &mut String,
    value: &str,
    in_attribute: bool,
    normalise_white: bool,
    strip_leading: bool,
    trim_trailing: bool,
) {
    let mut last_was_white = false;
    let mut reached_non_white = false;
    let mut skipped = false;
    for c in value.chars() {
        if normalise_white {
            if is_whitespace(c) {
                if (strip_leading && !reached_non_white) || last_was_white {
                    continue;
                }
                if trim_trailing {
                    skipped = true;
                    continue;
                }
                accum.push(' ');
                last_was_white = true;
                continue;
            }
            last_was_white = false;
            reached_non_white = true;
            if skipped {
                accum.push(' ');
                skipped = false;
            }
        }
        match c {
            '&' => accum.push_str("&amp;"),
            '\u{a0}' => accum.push_str("&nbsp;"),
            '<' if !in_attribute => accum.push_str("&lt;"),
            '>' if !in_attribute => accum.push_str("&gt;"),
            '"' if in_attribute => accum.push_str("&quot;"),
            _ => {
                if (c as u32) < 0x20 && !matches!(c, '\t' | '\n' | '\r') {
                    accum.push_str(&format!("&#{};", c as u32));
                } else {
                    accum.push(c);
                }
            }
        }
    }
}

/// jsoup `Attribute.booleanAttributes`.
const BOOLEAN_ATTRIBUTES: &[&str] = &[
    "allowfullscreen", "async", "autofocus", "checked", "compact", "declare", "default",
    "defaultchecked", "defaultmuted", "defaultselected", "defer", "disabled", "enabled",
    "formnovalidate", "hidden", "indeterminate", "inert", "ismap", "itemscope", "loop", "multiple",
    "muted", "nohref", "noresize", "noshade", "novalidate", "nowrap", "open", "pauseonexit",
    "readonly", "required", "reversed", "scoped", "seamless", "selected", "sortable", "truespeed",
    "typemustmatch", "visible",
];

fn is_boolean_attribute(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    BOOLEAN_ATTRIBUTES.binary_search(&lower.as_str()).is_ok()
}

/// Keeps the shared text-normalisation helper referenced from the serializer.
#[allow(dead_code)]
fn whitespace_tail(accum: &str) -> bool {
    last_char_is_whitespace(accum)
}
