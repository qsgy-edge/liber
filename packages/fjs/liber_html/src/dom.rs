//! Arena DOM built from html5ever, carrying the frozen baseline's node semantics.
//!
//! The frozen reader parses with jsoup and reads the tree through jsoup's node
//! API: `text()`, `ownText()`, `wholeText()`, `data()`, sibling indices, and the
//! block/inline/empty tag tables that drive whitespace and serialization. This
//! module keeps those semantics in one place so the rule layer above it can be
//! a straight port instead of a collection of approximations.

use html5ever::tendril::TendrilSink;
use html5ever::{ParseOpts, parse_document};
use markup5ever_rcdom::{Handle, NodeData as RcData, RcDom};

pub type NodeId = usize;

#[derive(Debug, Clone, PartialEq)]
pub enum NodeKind {
    Document,
    Doctype { name: String },
    Text { text: String },
    /// Text inside `script`/`style`, which jsoup models as a data node.
    Data { text: String },
    Comment { text: String },
    Element { name: String, attrs: Vec<(String, String)> },
}

#[derive(Debug, Clone)]
pub struct Node {
    pub parent: Option<NodeId>,
    pub children: Vec<NodeId>,
    pub kind: NodeKind,
}

#[derive(Debug, Clone, Default)]
pub struct Dom {
    pub nodes: Vec<Node>,
}

impl Dom {
    /// Parses a document the way the frozen `Jsoup.parse(String)` does.
    pub fn parse(html: &str) -> Dom {
        let rc: RcDom = parse_document(RcDom::default(), ParseOpts::default())
            .from_utf8()
            .read_from(&mut html.as_bytes())
            .expect("html5ever reads from an in-memory buffer");
        let mut dom = Dom { nodes: Vec::new() };
        dom.nodes.push(Node { parent: None, children: Vec::new(), kind: NodeKind::Document });
        let root = rc.document.clone();
        let children = root.children.borrow().clone();
        for child in children {
            dom.append_rc(child, 0, None);
        }
        dom
    }

    fn append_rc(&mut self, handle: Handle, parent: NodeId, parent_tag: Option<&str>) -> NodeId {
        let (kind, children) = match &handle.data {
            RcData::Document => (NodeKind::Document, handle.children.borrow().clone()),
            RcData::Doctype { name, .. } => {
                (NodeKind::Doctype { name: name.to_string() }, Vec::new())
            }
            RcData::Text { contents } => {
                let text = contents.borrow().to_string();
                let kind = if is_raw_text_tag(parent_tag) {
                    NodeKind::Data { text }
                } else {
                    NodeKind::Text { text }
                };
                (kind, Vec::new())
            }
            RcData::Comment { contents } => (NodeKind::Comment { text: contents.to_string() }, Vec::new()),
            RcData::ProcessingInstruction { .. } => {
                (NodeKind::Comment { text: String::new() }, Vec::new())
            }
            RcData::Element { name, attrs, .. } => {
                let attributes = attrs
                    .borrow()
                    .iter()
                    .map(|a| (a.name.local.to_string(), a.value.to_string()))
                    .collect();
                (NodeKind::Element { name: name.local.to_string(), attrs: attributes }, handle.children.borrow().clone())
            }
        };
        let id = self.nodes.len();
        self.nodes.push(Node { parent: Some(parent), children: Vec::new(), kind });
        self.nodes[parent].children.push(id);
        let tag = match &self.nodes[id].kind {
            NodeKind::Element { name, .. } => Some(name.as_str()),
            _ => parent_tag,
        };
        let tag = tag.map(|value| value.to_string());
        for child in children {
            self.append_rc(child, id, tag.as_deref());
        }
        id
    }

    pub fn kind(&self, id: NodeId) -> &NodeKind {
        &self.nodes[id].kind
    }

    pub fn is_element(&self, id: NodeId) -> bool {
        matches!(self.nodes[id].kind, NodeKind::Element { .. })
    }

    pub fn element_name(&self, id: NodeId) -> Option<&str> {
        match &self.nodes[id].kind {
            NodeKind::Element { name, .. } => Some(name),
            _ => None,
        }
    }

    pub fn is_tag(&self, id: NodeId, name: &str) -> bool {
        self.element_name(id) == Some(name)
    }

    pub fn attributes(&self, id: NodeId) -> &[(String, String)] {
        match &self.nodes[id].kind {
            NodeKind::Element { attrs, .. } => attrs,
            _ => &[],
        }
    }

    pub fn attr(&self, id: NodeId, key: &str) -> Option<&str> {
        self.attributes(id)
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(key))
            .map(|(_, value)| value.as_str())
    }

    pub fn has_attr(&self, id: NodeId, key: &str) -> bool {
        self.attr(id, key).is_some()
    }

    pub fn id_attr(&self, id: NodeId) -> &str {
        self.attr(id, "id").unwrap_or("")
    }

    pub fn class_attr(&self, id: NodeId) -> &str {
        self.attr(id, "class").unwrap_or("")
    }

    /// jsoup `Element.hasClass`: case-insensitive token comparison, whole tokens only.
    pub fn has_class(&self, id: NodeId, class_name: &str) -> bool {
        if class_name.is_empty() {
            return false;
        }
        self.class_attr(id)
            .split_whitespace()
            .any(|token| token.eq_ignore_ascii_case(class_name))
    }

    pub fn parent(&self, id: NodeId) -> Option<NodeId> {
        self.nodes[id].parent
    }

    pub fn children(&self, id: NodeId) -> &[NodeId] {
        &self.nodes[id].children
    }

    /// Element children in document order, as jsoup `Element.children()`.
    pub fn element_children(&self, id: NodeId) -> Vec<NodeId> {
        self.nodes[id].children.iter().copied().filter(|child| self.is_element(*child)).collect()
    }

    pub fn first_element_child(&self, id: NodeId) -> Option<NodeId> {
        self.nodes[id].children.iter().copied().find(|child| self.is_element(*child))
    }

    pub fn last_element_child(&self, id: NodeId) -> Option<NodeId> {
        self.nodes[id].children.iter().rev().copied().find(|child| self.is_element(*child))
    }

    /// jsoup `Element.elementSiblingIndex`: 0-based index among element siblings.
    pub fn element_sibling_index(&self, id: NodeId) -> usize {
        let Some(parent) = self.parent(id) else { return 0 };
        self.element_children(parent).iter().position(|child| *child == id).unwrap_or(0)
    }

    pub fn sibling_element_count(&self, id: NodeId) -> usize {
        match self.parent(id) {
            Some(parent) => self.element_children(parent).len(),
            None => 1,
        }
    }

    pub fn next_element_sibling(&self, id: NodeId) -> Option<NodeId> {
        let parent = self.parent(id)?;
        let children = self.element_children(parent);
        let index = children.iter().position(|child| *child == id)?;
        children.get(index + 1).copied()
    }

    pub fn previous_element_sibling(&self, id: NodeId) -> Option<NodeId> {
        let parent = self.parent(id)?;
        let children = self.element_children(parent);
        let index = children.iter().position(|child| *child == id)?;
        index.checked_sub(1).and_then(|previous| children.get(previous).copied())
    }

    pub fn sibling_elements(&self, id: NodeId) -> Vec<NodeId> {
        let Some(parent) = self.parent(id) else { return Vec::new() };
        self.element_children(parent).into_iter().filter(|child| *child != id).collect()
    }

    pub fn next_sibling(&self, id: NodeId) -> Option<NodeId> {
        let parent = self.parent(id)?;
        let children = &self.nodes[parent].children;
        let index = children.iter().position(|child| *child == id)?;
        children.get(index + 1).copied()
    }

    pub fn previous_sibling(&self, id: NodeId) -> Option<NodeId> {
        let parent = self.parent(id)?;
        let children = &self.nodes[parent].children;
        let index = children.iter().position(|child| *child == id)?;
        index.checked_sub(1).and_then(|previous| children.get(previous).copied())
    }

    /// The document's root element (`<html>` after a tolerant parse).
    pub fn root_element(&self) -> Option<NodeId> {
        self.first_element_child(0)
    }

    /// jsoup `Element.text()`: normalised text with jsoup's block/`br` spacing.
    pub fn text(&self, id: NodeId) -> String {
        let mut accum = String::new();
        self.text_accum(id, &mut accum);
        accum.trim().to_string()
    }

    fn text_accum(&self, id: NodeId, accum: &mut String) {
        match self.kind(id) {
            NodeKind::Text { text } => {
                let preserve = self.preserve_whitespace(self.parent(id));
                append_normalised_text(accum, text, preserve);
            }
            NodeKind::Element { name, .. } => {
                if !accum.is_empty()
                    && (is_block(name) || name == "br")
                    && !last_char_is_whitespace(accum)
                {
                    accum.push(' ');
                }
            }
            _ => {}
        }
        for child in self.children(id).to_vec() {
            self.text_accum(child, accum);
        }
        if let Some(name) = self.element_name(id) {
            if is_block(name) {
                let next = self.next_sibling(id);
                let spaced = match next {
                    Some(next) if matches!(self.kind(next), NodeKind::Text { .. }) => true,
                    Some(next) if self.is_element(next) => {
                        !format_as_block(self.element_name(next).unwrap_or(""))
                    }
                    _ => false,
                };
                if spaced && !last_char_is_whitespace(accum) {
                    accum.push(' ');
                }
            }
        }
    }

    /// jsoup `Element.ownText()`: direct text children only.
    pub fn own_text(&self, id: NodeId) -> String {
        let mut accum = String::new();
        for child in self.children(id).to_vec() {
            match self.kind(child) {
                NodeKind::Text { text } => {
                    let preserve = self.preserve_whitespace(Some(id));
                    append_normalised_text(&mut accum, text, preserve);
                }
                NodeKind::Element { name, .. } => {
                    if name == "br" && !last_char_is_whitespace(&accum) {
                        accum.push(' ');
                    }
                }
                _ => {}
            }
        }
        accum.trim().to_string()
    }

    /// jsoup `Element.wholeText()`: raw text including descendants, `br` as newline.
    pub fn whole_text(&self, id: NodeId) -> String {
        let mut accum = String::new();
        self.whole_text_accum(id, &mut accum);
        accum
    }

    fn whole_text_accum(&self, id: NodeId, accum: &mut String) {
        match self.kind(id) {
            NodeKind::Text { text } => accum.push_str(text),
            NodeKind::Data { text } => accum.push_str(text),
            NodeKind::Element { name, .. } if name == "br" => accum.push('\n'),
            _ => {}
        }
        for child in self.children(id).to_vec() {
            self.whole_text_accum(child, accum);
        }
    }

    /// jsoup `Element.wholeOwnText()`: raw direct text, `br` as newline.
    pub fn whole_own_text(&self, id: NodeId) -> String {
        let mut accum = String::new();
        for child in self.children(id).to_vec() {
            match self.kind(child) {
                NodeKind::Text { text } | NodeKind::Data { text } => accum.push_str(text),
                NodeKind::Element { name, .. } if name == "br" => accum.push('\n'),
                _ => {}
            }
        }
        accum
    }

    /// jsoup `Element.data()`: data, cdata and comment contents of the subtree.
    pub fn data(&self, id: NodeId) -> String {
        let mut accum = String::new();
        self.data_accum(id, &mut accum);
        accum
    }

    fn data_accum(&self, id: NodeId, accum: &mut String) {
        match self.kind(id) {
            NodeKind::Data { text } | NodeKind::Comment { text } => accum.push_str(text),
            _ => {}
        }
        for child in self.children(id).to_vec() {
            self.data_accum(child, accum);
        }
    }

    /// jsoup `Element.preserveWhitespace`: `pre`, `plaintext`, `title`, `textarea`
    /// on the node or one of its six nearest ancestors.
    pub fn preserve_whitespace(&self, id: Option<NodeId>) -> bool {
        let mut current = id;
        let mut depth = 0;
        while let Some(node) = current {
            if let Some(name) = self.element_name(node) {
                if preserve_whitespace_tag(name) {
                    return true;
                }
            }
            current = self.parent(node);
            depth += 1;
            if depth >= 6 {
                break;
            }
        }
        false
    }

    /// jsoup `Element.hasText()`: any non-blank text node in the subtree.
    pub fn has_text(&self, id: NodeId) -> bool {
        if let NodeKind::Text { text } = self.kind(id) {
            if !is_blank(text) {
                return true;
            }
        }
        self.children(id).iter().any(|child| self.has_text(*child))
    }

    /// jsoup `Element.isBlank()` on a text node.
    pub fn text_is_blank(&self, id: NodeId) -> bool {
        match self.kind(id) {
            NodeKind::Text { text } | NodeKind::Data { text } => is_blank(text),
            _ => true,
        }
    }

    /// Follows jsoup's pre-order traversal: the node itself, then its children.
    pub fn traverse(&self, id: NodeId, visit: &mut dyn FnMut(NodeId)) {
        visit(id);
        for child in self.children(id).to_vec() {
            self.traverse(child, visit);
        }
    }
}

pub fn is_raw_text_tag(name: Option<&str>) -> bool {
    matches!(name, Some("script") | Some("style"))
}

pub fn is_blank(value: &str) -> bool {
    value.chars().all(is_whitespace)
}

pub fn is_whitespace(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\u{c}' | '\r')
}

pub fn is_actually_whitespace(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\u{c}' | '\r' | '\u{a0}')
}

pub fn is_invisible_char(c: char) -> bool {
    matches!(c, '\u{200b}' | '\u{ad}')
}

pub fn last_char_is_whitespace(accum: &str) -> bool {
    accum.ends_with(' ')
}

/// jsoup `StringUtil.appendNormalisedWhitespace`.
pub fn append_normalised_whitespace(accum: &mut String, value: &str, strip_leading: bool) {
    let mut last_was_white = false;
    let mut reached_non_white = false;
    for c in value.chars() {
        if is_actually_whitespace(c) {
            if (strip_leading && !reached_non_white) || last_was_white {
                continue;
            }
            accum.push(' ');
            last_was_white = true;
        } else if !is_invisible_char(c) {
            accum.push(c);
            last_was_white = false;
            reached_non_white = true;
        }
    }
}

/// jsoup `StringUtil.normaliseWhitespace`.
pub fn normalise_whitespace(value: &str) -> String {
    let mut accum = String::new();
    append_normalised_whitespace(&mut accum, value, false);
    accum
}

fn append_normalised_text(accum: &mut String, text: &str, preserve: bool) {
    if preserve {
        accum.push_str(text);
    } else {
        append_normalised_whitespace(accum, text, last_char_is_whitespace(accum));
    }
}

// jsoup `Tag` tables (jsoup 1.16.2 `Tag.java`).
const BLOCK_TAGS: &[&str] = &[
    "html", "head", "body", "frameset", "script", "noscript", "style", "meta", "link", "title",
    "frame", "noframes", "section", "nav", "aside", "hgroup", "header", "footer", "p", "h1", "h2",
    "h3", "h4", "h5", "h6", "ul", "ol", "pre", "div", "blockquote", "hr", "address", "figure",
    "figcaption", "form", "fieldset", "ins", "del", "dl", "dt", "dd", "li", "table", "caption",
    "thead", "tfoot", "tbody", "colgroup", "col", "tr", "th", "td", "video", "audio", "canvas",
    "details", "menu", "plaintext", "template", "article", "main", "svg", "math", "center", "dir",
    "applet", "marquee", "listing",
];

const INLINE_TAGS: &[&str] = &[
    "object", "base", "font", "tt", "i", "b", "u", "big", "small", "em", "strong", "dfn", "code",
    "samp", "kbd", "var", "cite", "abbr", "time", "acronym", "mark", "ruby", "rt", "rp", "rtc", "a",
    "img", "br", "wbr", "map", "q", "sub", "sup", "bdo", "iframe", "embed", "span", "input",
    "select", "textarea", "label", "button", "optgroup", "option", "legend", "datalist", "keygen",
    "output", "progress", "meter", "area", "param", "source", "track", "summary", "command",
    "device", "basefont", "bgsound", "menuitem", "data", "bdi", "s", "strike", "nobr", "rb", "text",
    "mi", "mo", "msup", "mn", "mtext",
];

const EMPTY_TAGS: &[&str] = &[
    "meta", "link", "base", "frame", "img", "br", "wbr", "embed", "hr", "input", "keygen", "col",
    "command", "device", "area", "basefont", "bgsound", "menuitem", "param", "source", "track",
];

const FORMAT_AS_INLINE_TAGS: &[&str] = &[
    "title", "a", "p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "address", "li", "th", "td",
    "script", "style", "ins", "del", "s",
];

const PRESERVE_WHITESPACE_TAGS: &[&str] = &["pre", "plaintext", "title", "textarea"];

/// jsoup `Tag.isBlock`: unknown tags default to block.
pub fn is_block(name: &str) -> bool {
    if INLINE_TAGS.contains(&name) {
        return false;
    }
    if BLOCK_TAGS.contains(&name) {
        return true;
    }
    true
}

/// jsoup `Tag.formatAsBlock`: unknown tags default to block.
pub fn format_as_block(name: &str) -> bool {
    if FORMAT_AS_INLINE_TAGS.contains(&name) {
        return false;
    }
    !INLINE_TAGS.contains(&name)
}

/// jsoup `Tag.isSelfClosing` in the HTML syntax: void elements only.
pub fn is_empty_tag(name: &str) -> bool {
    EMPTY_TAGS.contains(&name)
}

pub fn preserve_whitespace_tag(name: &str) -> bool {
    PRESERVE_WHITESPACE_TAGS.contains(&name)
}
