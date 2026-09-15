//! A port of jsoup 1.16.2's selector engine (`QueryParser`, `Evaluator`,
//! `StructuralEvaluator`, `CombiningEvaluator`, `Collector`).
//!
//! The frozen reader selects with jsoup's own parser, not with standard CSS:
//! `:eq`/`:lt`/`:gt` index element siblings, `:nth-last-child` counts from the
//! end without the CSS `+ 1`, `:contains` lower-cases both sides, attribute
//! values compare case-insensitively, and `:has` evaluates its sub-selector with
//! the subject element as the root. Reproducing those rules is the point of the
//! adapter, so this file follows the Java source operation by operation.

use crate::dom::{Dom, NodeId, NodeKind, is_blank, normalise_whitespace};
use fancy_regex::Regex;

#[derive(Debug, Clone)]
pub struct SelectError {
    pub message: String,
}

impl SelectError {
    fn new(message: impl Into<String>) -> SelectError {
        SelectError { message: message.into() }
    }
}

#[derive(Debug, Clone)]
pub enum Nth {
    Child { a: i64, b: i64 },
    LastChild { a: i64, b: i64 },
    OfType { a: i64, b: i64 },
    LastOfType { a: i64, b: i64 },
}

#[derive(Debug, Clone)]
pub enum Evaluator {
    All,
    Tag(String),
    TagEndsWith(String),
    Id(String),
    Class(String),
    Attribute(String),
    AttributeStarting(String),
    AttributeWithValue { key: String, value: String },
    AttributeWithValueNot { key: String, value: String },
    AttributeWithValueStarting { key: String, value: String },
    AttributeWithValueEnding { key: String, value: String },
    AttributeWithValueContaining { key: String, value: String },
    AttributeWithValueMatching { key: String, pattern: Regex },
    IndexLessThan(i64),
    IndexGreaterThan(i64),
    IndexEquals(i64),
    IsFirstChild,
    IsLastChild,
    IsFirstOfType,
    IsLastOfType,
    IsOnlyChild,
    IsOnlyOfType,
    IsEmpty,
    IsRoot,
    Nth(Nth),
    ContainsText(String),
    ContainsOwnText(String),
    ContainsWholeText(String),
    ContainsWholeOwnText(String),
    ContainsData(String),
    Matches(Regex),
    MatchesOwn(Regex),
    MatchesWholeText(Regex),
    MatchesWholeOwnText(Regex),
    StructuralRoot,
    Has(Box<Evaluator>),
    Not(Box<Evaluator>),
    Parent(Box<Evaluator>),
    ImmediateParent(Box<Evaluator>),
    ImmediateParentRun(Vec<Evaluator>),
    PreviousSibling(Box<Evaluator>),
    ImmediatePreviousSibling(Box<Evaluator>),
    And(Vec<Evaluator>),
    Or(Vec<Evaluator>),
}

impl Evaluator {
    pub fn matches(&self, dom: &Dom, root: NodeId, element: NodeId) -> bool {
        match self {
            Evaluator::All => true,
            Evaluator::Tag(tag) => dom.element_name(element).map(|name| name.eq_ignore_ascii_case(tag)).unwrap_or(false),
            Evaluator::TagEndsWith(tag) => dom
                .element_name(element)
                .map(|name| name.to_ascii_lowercase().ends_with(&tag.to_ascii_lowercase()))
                .unwrap_or(false),
            Evaluator::Id(id) => dom.id_attr(element) == id,
            Evaluator::Class(class_name) => dom.has_class(element, class_name),
            Evaluator::Attribute(key) => dom.has_attr(element, key),
            Evaluator::AttributeStarting(prefix) => dom
                .attributes(element)
                .iter()
                .any(|(key, _)| key.to_ascii_lowercase().starts_with(prefix.as_str())),
            Evaluator::AttributeWithValue { key, value } => {
                dom.has_attr(element, key) && value.eq_ignore_ascii_case(dom.attr(element, key).unwrap_or("").trim())
            }
            Evaluator::AttributeWithValueNot { key, value } => {
                !value.eq_ignore_ascii_case(dom.attr(element, key).unwrap_or(""))
            }
            Evaluator::AttributeWithValueStarting { key, value } => {
                dom.has_attr(element, key) && dom.attr(element, key).unwrap_or("").to_lowercase().starts_with(value.as_str())
            }
            Evaluator::AttributeWithValueEnding { key, value } => {
                dom.has_attr(element, key) && dom.attr(element, key).unwrap_or("").to_lowercase().ends_with(value.as_str())
            }
            Evaluator::AttributeWithValueContaining { key, value } => {
                dom.has_attr(element, key) && dom.attr(element, key).unwrap_or("").to_lowercase().contains(value.as_str())
            }
            Evaluator::AttributeWithValueMatching { key, pattern } => {
                dom.has_attr(element, key) && pattern.find(dom.attr(element, key).unwrap_or("")).map(|m| m.is_some()).unwrap_or(false)
            }
            Evaluator::IndexLessThan(index) => root != element && (dom.element_sibling_index(element) as i64) < *index,
            Evaluator::IndexGreaterThan(index) => (dom.element_sibling_index(element) as i64) > *index,
            Evaluator::IndexEquals(index) => (dom.element_sibling_index(element) as i64) == *index,
            Evaluator::IsFirstChild => dom
                .parent(element)
                .map(|parent| !matches!(dom.kind(parent), NodeKind::Document) && dom.first_element_child(parent) == Some(element))
                .unwrap_or(false),
            Evaluator::IsLastChild => dom
                .parent(element)
                .map(|parent| !matches!(dom.kind(parent), NodeKind::Document) && dom.last_element_child(parent) == Some(element))
                .unwrap_or(false),
            Evaluator::IsFirstOfType => nth_of_type(dom, element) == Some(1),
            Evaluator::IsLastOfType => nth_last_of_type(dom, element) == Some(1),
            Evaluator::IsOnlyChild => dom
                .parent(element)
                .map(|parent| !matches!(dom.kind(parent), NodeKind::Document) && dom.sibling_elements(element).is_empty())
                .unwrap_or(false),
            Evaluator::IsOnlyOfType => only_of_type(dom, element),
            Evaluator::IsEmpty => {
                for child in dom.children(element) {
                    match dom.kind(*child) {
                        NodeKind::Text { text } => return is_blank(text),
                        NodeKind::Comment { .. } | NodeKind::Doctype { .. } => {}
                        _ => return false,
                    }
                }
                true
            }
            Evaluator::IsRoot => {
                let root_element = if matches!(dom.kind(root), NodeKind::Document) {
                    dom.root_element()
                } else {
                    Some(root)
                };
                root_element == Some(element)
            }
            Evaluator::Nth(nth) => match nth {
                Nth::Child { a, b } => {
                    let Some(pos) = nth_child_position(dom, element) else { return false };
                    nth_matches(*a, *b, pos)
                }
                Nth::LastChild { a, b } => {
                    let Some(parent) = dom.parent(element) else { return false };
                    if matches!(dom.kind(parent), NodeKind::Document) {
                        return false;
                    }
                    let pos = (dom.sibling_element_count(element) as i64) - (dom.element_sibling_index(element) as i64);
                    nth_matches(*a, *b, pos)
                }
                Nth::OfType { a, b } => {
                    let Some(pos) = nth_of_type(dom, element) else { return false };
                    nth_matches(*a, *b, pos)
                }
                Nth::LastOfType { a, b } => {
                    let Some(pos) = nth_last_of_type(dom, element) else { return false };
                    nth_matches(*a, *b, pos)
                }
            },
            Evaluator::ContainsText(search) => dom.text(element).to_lowercase().contains(&search.to_lowercase()),
            Evaluator::ContainsOwnText(search) => dom.own_text(element).to_lowercase().contains(&search.to_lowercase()),
            Evaluator::ContainsWholeText(search) => dom.whole_text(element).contains(search.as_str()),
            Evaluator::ContainsWholeOwnText(search) => dom.whole_own_text(element).contains(search.as_str()),
            Evaluator::ContainsData(search) => dom.data(element).to_lowercase().contains(&search.to_lowercase()),
            Evaluator::Matches(pattern) => pattern_matches(pattern, &dom.text(element)),
            Evaluator::MatchesOwn(pattern) => pattern_matches(pattern, &dom.own_text(element)),
            Evaluator::MatchesWholeText(pattern) => pattern_matches(pattern, &dom.whole_text(element)),
            Evaluator::MatchesWholeOwnText(pattern) => pattern_matches(pattern, &dom.whole_own_text(element)),
            Evaluator::StructuralRoot => root == element,
            Evaluator::Has(inner) => {
                for child in dom.element_children(element) {
                    if find_first(dom, element, child, inner).is_some() {
                        return true;
                    }
                }
                false
            }
            Evaluator::Not(inner) => !inner.matches(dom, root, element),
            Evaluator::Parent(inner) => {
                if root == element {
                    return false;
                }
                let mut current = dom.parent(element);
                while let Some(parent) = current {
                    if inner.matches(dom, root, parent) {
                        return true;
                    }
                    if parent == root {
                        break;
                    }
                    current = dom.parent(parent);
                }
                false
            }
            Evaluator::ImmediateParent(inner) => {
                if root == element {
                    return false;
                }
                dom.parent(element).map(|parent| inner.matches(dom, root, parent)).unwrap_or(false)
            }
            Evaluator::ImmediateParentRun(run) => {
                let mut current = Some(element);
                for eval in run.iter().rev() {
                    let Some(node) = current else { return false };
                    if !eval.matches(dom, root, node) {
                        return false;
                    }
                    current = dom.parent(node);
                }
                true
            }
            Evaluator::PreviousSibling(inner) => {
                if root == element {
                    return false;
                }
                let mut sibling = dom.parent(element).and_then(|parent| dom.first_element_child(parent));
                while let Some(current) = sibling {
                    if current == element {
                        break;
                    }
                    if inner.matches(dom, root, current) {
                        return true;
                    }
                    sibling = dom.next_element_sibling(current);
                }
                false
            }
            Evaluator::ImmediatePreviousSibling(inner) => {
                if root == element {
                    return false;
                }
                dom.previous_element_sibling(element).map(|previous| inner.matches(dom, root, previous)).unwrap_or(false)
            }
            Evaluator::And(evals) => evals.iter().all(|eval| eval.matches(dom, root, element)),
            Evaluator::Or(evals) => evals.iter().any(|eval| eval.matches(dom, root, element)),
        }
    }

    fn replace_right_most(&mut self, replacement: Evaluator) {
        if let Evaluator::Or(evals) = self {
            if let Some(last) = evals.last_mut() {
                *last = replacement;
            }
        }
    }
}

fn pattern_matches(pattern: &Regex, value: &str) -> bool {
    pattern.find(value).map(|m| m.is_some()).unwrap_or(false)
}

fn nth_matches(a: i64, b: i64, pos: i64) -> bool {
    if a == 0 {
        return pos == b;
    }
    (pos - b) * a >= 0 && (pos - b) % a == 0
}

/// jsoup `IsNthChild.calculatePosition`: 1-based element sibling index.
fn nth_child_position(dom: &Dom, element: NodeId) -> Option<i64> {
    let parent = dom.parent(element)?;
    if matches!(dom.kind(parent), NodeKind::Document) {
        return None;
    }
    Some(dom.element_sibling_index(element) as i64 + 1)
}

/// jsoup `IsNthOfType.calculatePosition`: counts same-named nodes up to the element.
fn nth_of_type(dom: &Dom, element: NodeId) -> Option<i64> {
    let parent = dom.parent(element)?;
    let name = dom.element_name(element)?;
    let mut pos = 0;
    for child in dom.children(parent) {
        if dom.element_name(*child).map(|child_name| child_name == name).unwrap_or(false) {
            pos += 1;
        }
        if *child == element {
            break;
        }
    }
    Some(pos)
}

/// jsoup `IsNthLastOfType.calculatePosition`.
fn nth_last_of_type(dom: &Dom, element: NodeId) -> Option<i64> {
    dom.parent(element)?;
    let name = dom.element_name(element)?;
    let mut pos = 0;
    let mut next = Some(element);
    while let Some(current) = next {
        if dom.element_name(current).map(|current_name| current_name == name).unwrap_or(false) {
            pos += 1;
        }
        next = dom.next_element_sibling(current);
    }
    Some(pos)
}

fn only_of_type(dom: &Dom, element: NodeId) -> bool {
    let Some(parent) = dom.parent(element) else { return false };
    if matches!(dom.kind(parent), NodeKind::Document) {
        return false;
    }
    let Some(name) = dom.element_name(element) else { return false };
    let mut pos = 0;
    let mut next = dom.first_element_child(parent);
    while let Some(current) = next {
        if dom.element_name(current).map(|current_name| current_name == name).unwrap_or(false) {
            pos += 1;
        }
        if pos > 1 {
            break;
        }
        next = dom.next_element_sibling(current);
    }
    pos == 1
}

/// jsoup `Collector.collect`: pre-order traversal; the root itself is tested.
pub fn collect(dom: &Dom, root: NodeId, evaluator: &Evaluator) -> Vec<NodeId> {
    let mut out = Vec::new();
    dom.traverse(root, &mut |id| {
        if dom.is_element(id) && evaluator.matches(dom, root, id) {
            out.push(id);
        }
    });
    out
}

/// jsoup `Collector.FirstFinder`: first match in the subtree, with `root` as the
/// evaluation root and `start` as the traversal start.
pub fn find_first(dom: &Dom, root: NodeId, start: NodeId, evaluator: &Evaluator) -> Option<NodeId> {
    let mut found = None;
    dom.traverse(start, &mut |id| {
        if found.is_none() && dom.is_element(id) && evaluator.matches(dom, root, id) {
            found = Some(id);
        }
    });
    found
}

/// jsoup `Element.select`.
pub fn select(dom: &Dom, root: NodeId, query: &str) -> Result<Vec<NodeId>, SelectError> {
    let evaluator = parse(query)?;
    Ok(collect(dom, root, &evaluator))
}

pub fn parse(query: &str) -> Result<Evaluator, SelectError> {
    if query.trim().is_empty() {
        return Err(SelectError::new("String must not be empty"));
    }
    let mut parser = Parser::new(query);
    parser.parse()
}

const COMBINATORS: [char; 5] = [',', '>', '+', '~', ' '];
const ATTRIBUTE_EVALS: [&str; 6] = ["=", "!=", "^=", "$=", "*=", "~="];

struct Parser {
    chars: Vec<char>,
    pos: usize,
    query: String,
}

impl Parser {
    fn new(query: &str) -> Parser {
        Parser { chars: query.trim().chars().collect(), pos: 0, query: query.trim().to_string() }
    }

    fn parse(&mut self) -> Result<Evaluator, SelectError> {
        self.consume_whitespace();
        let mut evals: Vec<Evaluator> = Vec::new();
        if self.matches_any_chars(&COMBINATORS) {
            evals.push(Evaluator::StructuralRoot);
            let combinator = self.consume();
            return self.combinator(combinator, evals);
        }
        evals.push(self.consume_evaluator()?);

        while !self.is_empty() {
            let seen_white = self.consume_whitespace();
            if self.matches_any_chars(&COMBINATORS) {
                let combinator = self.consume();
                evals = vec![self.combinator(combinator, evals)?];
            } else if seen_white {
                evals = vec![self.combinator(' ', evals)?];
            } else {
                evals.push(self.consume_evaluator()?);
            }
        }

        if evals.len() == 1 {
            return Ok(evals.pop().unwrap());
        }
        Ok(Evaluator::And(evals))
    }

    fn combinator(&mut self, combinator: char, evals: Vec<Evaluator>) -> Result<Evaluator, SelectError> {
        self.consume_whitespace();
        let sub_query = self.consume_sub_query()?;
        let new_eval = parse(&sub_query)?;

        let mut root_eval;
        let mut current_eval;
        let mut replace_right_most = false;
        if evals.len() == 1 {
            let single = evals[0].clone();
            let right_most = match &single {
                Evaluator::Or(or_evals) if combinator != ',' => or_evals.last().cloned(),
                _ => None,
            };
            if let Some(right_most) = right_most {
                root_eval = single.clone();
                current_eval = right_most;
                replace_right_most = true;
            } else {
                root_eval = single.clone();
                current_eval = single;
            }
        } else {
            root_eval = Evaluator::And(evals);
            current_eval = root_eval.clone();
        }

        current_eval = match combinator {
            '>' => match current_eval {
                Evaluator::ImmediateParentRun(mut run) => {
                    run.push(new_eval);
                    Evaluator::ImmediateParentRun(run)
                }
                other => Evaluator::ImmediateParentRun(vec![other, new_eval]),
            },
            ' ' => Evaluator::And(vec![Evaluator::Parent(Box::new(current_eval)), new_eval]),
            '+' => Evaluator::And(vec![Evaluator::ImmediatePreviousSibling(Box::new(current_eval)), new_eval]),
            '~' => Evaluator::And(vec![Evaluator::PreviousSibling(Box::new(current_eval)), new_eval]),
            ',' => match current_eval {
                Evaluator::Or(mut or) => {
                    or.push(new_eval);
                    Evaluator::Or(or)
                }
                other => Evaluator::Or(vec![other, new_eval]),
            },
            other => return Err(SelectError::new(format!("Unknown combinator '{}'", other))),
        };

        if replace_right_most {
            root_eval.replace_right_most(current_eval);
        } else {
            root_eval = current_eval;
        }
        Ok(root_eval)
    }

    fn consume_sub_query(&mut self) -> Result<String, SelectError> {
        let mut sub = String::new();
        while !self.is_empty() {
            if self.matches("(") {
                sub.push('(');
                sub.push_str(&self.chomp_balanced('(', ')')?);
                sub.push(')');
            } else if self.matches("[") {
                sub.push('[');
                sub.push_str(&self.chomp_balanced('[', ']')?);
                sub.push(']');
            } else if self.matches_any_chars(&COMBINATORS) {
                if !sub.is_empty() {
                    break;
                }
                self.pos += 1;
            } else {
                sub.push(self.consume());
            }
        }
        Ok(sub)
    }

    fn consume_evaluator(&mut self) -> Result<Evaluator, SelectError> {
        if self.match_chomp("#") {
            return self.by_id();
        } else if self.match_chomp(".") {
            return self.by_class();
        } else if self.matches_word() || self.matches("*|") {
            return self.by_tag();
        } else if self.matches("[") {
            return self.by_attribute();
        } else if self.match_chomp("*") {
            return Ok(Evaluator::All);
        } else if self.match_chomp(":") {
            return self.parse_pseudo_selector();
        }
        Err(self.unexpected())
    }

    fn by_id(&mut self) -> Result<Evaluator, SelectError> {
        let id = self.consume_css_identifier();
        if id.is_empty() {
            return Err(self.unexpected());
        }
        Ok(Evaluator::Id(id))
    }

    fn by_class(&mut self) -> Result<Evaluator, SelectError> {
        let class_name = self.consume_css_identifier();
        if class_name.is_empty() {
            return Err(self.unexpected());
        }
        Ok(Evaluator::Class(class_name.trim().to_string()))
    }

    fn by_tag(&mut self) -> Result<Evaluator, SelectError> {
        let raw = normalize(&self.consume_element_selector());
        if raw.is_empty() {
            return Err(self.unexpected());
        }
        if let Some(plain) = raw.strip_prefix("*|") {
            let ends_with = raw.replace("*|", ":");
            return Ok(Evaluator::Or(vec![
                Evaluator::Tag(plain.to_string()),
                Evaluator::TagEndsWith(ends_with),
            ]));
        }
        let tag = if raw.contains('|') { raw.replace('|', ":") } else { raw };
        Ok(Evaluator::Tag(tag))
    }

    fn by_attribute(&mut self) -> Result<Evaluator, SelectError> {
        let content = self.chomp_balanced('[', ']')?;
        let mut cq = Parser::new(&content);
        let key = cq.consume_to_any(&ATTRIBUTE_EVALS);
        if key.trim().is_empty() {
            return Err(self.unexpected());
        }
        cq.consume_whitespace();
        if cq.is_empty() {
            if let Some(prefix) = key.strip_prefix('^') {
                return Ok(Evaluator::AttributeStarting(prefix.to_ascii_lowercase()));
            }
            return Ok(Evaluator::Attribute(key.trim().to_string()));
        }
        if cq.match_chomp("!=") {
            return Ok(Evaluator::AttributeWithValueNot { key: normalize(&key), value: attribute_value(cq.remainder(), true)? });
        }
        if cq.match_chomp("^=") {
            return Ok(Evaluator::AttributeWithValueStarting { key: normalize(&key), value: attribute_value(cq.remainder(), false)? });
        }
        if cq.match_chomp("$=") {
            return Ok(Evaluator::AttributeWithValueEnding { key: normalize(&key), value: attribute_value(cq.remainder(), false)? });
        }
        if cq.match_chomp("*=") {
            return Ok(Evaluator::AttributeWithValueContaining { key: normalize(&key), value: attribute_value(cq.remainder(), false)? });
        }
        if cq.match_chomp("~=") {
            let raw = cq.remainder();
            let pattern = Regex::new(&raw).map_err(|error| SelectError::new(format!("Pattern syntax error: {} ({})", raw, error)))?;
            return Ok(Evaluator::AttributeWithValueMatching { key: normalize(&key), pattern });
        }
        if cq.match_chomp("=") {
            return Ok(Evaluator::AttributeWithValue { key: normalize(&key), value: attribute_value(cq.remainder(), true)? });
        }
        Err(SelectError::new(format!("Could not parse attribute query '{}': unexpected token at '{}'", self.query, cq.remainder())))
    }

    fn parse_pseudo_selector(&mut self) -> Result<Evaluator, SelectError> {
        let pseudo = self.consume_css_identifier();
        let eval = match pseudo.as_str() {
            "lt" => Evaluator::IndexLessThan(self.consume_index()?),
            "gt" => Evaluator::IndexGreaterThan(self.consume_index()?),
            "eq" => Evaluator::IndexEquals(self.consume_index()?),
            "has" => {
                let sub_query = self.consume_parens()?;
                if sub_query.is_empty() {
                    return Err(SelectError::new(":has(selector) sub-select must not be empty"));
                }
                Evaluator::Has(Box::new(parse(&sub_query)?))
            }
            "contains" => Evaluator::ContainsText(lower_normalised(pseudo_argument(
                self.consume_parens()?,
                ":contains",
            )?)),
            "containsOwn" => Evaluator::ContainsOwnText(lower_normalised(pseudo_argument(
                self.consume_parens()?,
                ":containsOwn",
            )?)),
            "containsWholeText" => Evaluator::ContainsWholeText(pseudo_argument(self.consume_parens()?, ":containsWholeText")?),
            "containsWholeOwnText" => Evaluator::ContainsWholeOwnText(pseudo_argument(self.consume_parens()?, ":containsWholeOwnText")?),
            "containsData" => Evaluator::ContainsData(
                pseudo_argument(self.consume_parens()?, ":containsData")?.to_lowercase(),
            ),
            "matches" => Evaluator::Matches(compile_regex(&self.consume_parens()?, ":matches")?),
            "matchesOwn" => Evaluator::MatchesOwn(compile_regex(&self.consume_parens()?, ":matchesOwn")?),
            "matchesWholeText" => Evaluator::MatchesWholeText(compile_regex(&self.consume_parens()?, ":matchesWholeText")?),
            "matchesWholeOwnText" => Evaluator::MatchesWholeOwnText(compile_regex(&self.consume_parens()?, ":matchesWholeOwnText")?),
            "not" => {
                let sub_query = self.consume_parens()?;
                if sub_query.is_empty() {
                    return Err(SelectError::new(":not(selector) subselect must not be empty"));
                }
                Evaluator::Not(Box::new(parse(&sub_query)?))
            }
            "nth-child" => Evaluator::Nth(nth_from_arg(&self.consume_parens()?, NthKind::Child)?),
            "nth-last-child" => Evaluator::Nth(nth_from_arg(&self.consume_parens()?, NthKind::LastChild)?),
            "nth-of-type" => Evaluator::Nth(nth_from_arg(&self.consume_parens()?, NthKind::OfType)?),
            "nth-last-of-type" => Evaluator::Nth(nth_from_arg(&self.consume_parens()?, NthKind::LastOfType)?),
            "first-child" => Evaluator::IsFirstChild,
            "last-child" => Evaluator::IsLastChild,
            "first-of-type" => Evaluator::IsFirstOfType,
            "last-of-type" => Evaluator::IsLastOfType,
            "only-child" => Evaluator::IsOnlyChild,
            "only-of-type" => Evaluator::IsOnlyOfType,
            "empty" => Evaluator::IsEmpty,
            "root" => Evaluator::IsRoot,
            other => {
                return Err(SelectError::new(format!(
                    "Could not parse query '{}': unsupported pseudo-class :{}, remaining '{}'",
                    self.query,
                    other,
                    self.remainder()
                )));
            }
        };
        Ok(eval)
    }

    fn consume_index(&mut self) -> Result<i64, SelectError> {
        let index = self.consume_parens()?.trim().to_string();
        if index.is_empty() || !index.chars().all(|c| c.is_ascii_digit()) {
            return Err(SelectError::new("Index must be numeric"));
        }
        index.parse::<i64>().map_err(|error| SelectError::new(format!("Index must be numeric: {}", error)))
    }

    fn consume_parens(&mut self) -> Result<String, SelectError> {
        self.chomp_balanced('(', ')')
    }

    fn matches(&self, seq: &str) -> bool {
        let seq: Vec<char> = seq.chars().collect();
        if self.pos + seq.len() > self.chars.len() {
            return false;
        }
        self.chars[self.pos..self.pos + seq.len()]
            .iter()
            .zip(seq.iter())
            .all(|(a, b)| a.eq_ignore_ascii_case(b))
    }

    fn matches_any_chars(&self, chars: &[char]) -> bool {
        if self.is_empty() {
            return false;
        }
        chars.contains(&self.chars[self.pos])
    }

    fn matches_word(&self) -> bool {
        !self.is_empty() && self.chars[self.pos].is_alphanumeric()
    }

    fn match_chomp(&mut self, seq: &str) -> bool {
        if self.matches(seq) {
            self.pos += seq.chars().count();
            return true;
        }
        false
    }

    fn consume(&mut self) -> char {
        let c = self.chars[self.pos];
        self.pos += 1;
        c
    }

    fn consume_whitespace(&mut self) -> bool {
        let start = self.pos;
        while !self.is_empty() && crate::dom::is_whitespace(self.chars[self.pos]) {
            self.pos += 1;
        }
        self.pos > start
    }

    fn is_empty(&self) -> bool {
        self.pos >= self.chars.len()
    }

    fn remainder(&self) -> String {
        self.chars[self.pos..].iter().collect()
    }

    fn consume_to_any(&mut self, seq: &[&str]) -> String {
        let start = self.pos;
        while !self.is_empty() && !seq.iter().any(|s| self.matches(s)) {
            self.pos += 1;
        }
        self.chars[start..self.pos].iter().collect()
    }

    fn consume_css_identifier(&mut self) -> String {
        self.consume_escaped_css_identifier(&["-", "_"])
    }

    fn consume_element_selector(&mut self) -> String {
        self.consume_escaped_css_identifier(&["*|", "|", "_", "-"])
    }

    fn consume_escaped_css_identifier(&mut self, matches: &[&str]) -> String {
        let start = self.pos;
        let mut escaped = false;
        while !self.is_empty() {
            if self.chars[self.pos] == '\\' && self.chars.len() - self.pos > 1 {
                escaped = true;
                self.pos += 2;
            } else if self.matches_word() || matches.iter().any(|m| self.matches(m)) {
                self.pos += 1;
            } else {
                break;
            }
        }
        let consumed: String = self.chars[start..self.pos].iter().collect();
        if escaped { unescape(&consumed) } else { consumed }
    }

    fn chomp_balanced(&mut self, open: char, close: char) -> Result<String, SelectError> {
        let mut start: Option<usize> = None;
        let mut end: Option<usize> = None;
        let mut depth: i32 = 0;
        let mut last: char = '\0';
        let mut in_single_quote = false;
        let mut in_double_quote = false;
        let mut in_regex_qe = false;
        loop {
            if self.is_empty() {
                break;
            }
            let c = self.consume();
            if last != '\\' {
                if c == '\'' && c != open && !in_double_quote {
                    in_single_quote = !in_single_quote;
                } else if c == '"' && c != open && !in_single_quote {
                    in_double_quote = !in_double_quote;
                }
                if in_single_quote || in_double_quote || in_regex_qe {
                    last = c;
                    continue;
                }
                if c == open {
                    depth += 1;
                    if start.is_none() {
                        start = Some(self.pos);
                    }
                } else if c == close {
                    depth -= 1;
                }
            } else if c == 'Q' {
                in_regex_qe = true;
            } else if c == 'E' {
                in_regex_qe = false;
            }
            if depth > 0 && last != '\0' {
                end = Some(self.pos);
            }
            last = c;
            if depth <= 0 {
                break;
            }
        }
        let out = match (start, end) {
            (Some(start), Some(end)) if end >= start => self.chars[start..end].iter().collect(),
            _ => String::new(),
        };
        if depth > 0 {
            return Err(SelectError::new(format!("Did not find balanced marker at '{}'", out)));
        }
        Ok(out)
    }

    fn unexpected(&self) -> SelectError {
        SelectError::new(format!("Could not parse query '{}': unexpected token at '{}'", self.query, self.remainder()))
    }
}

enum NthKind {
    Child,
    LastChild,
    OfType,
    LastOfType,
}

fn nth_from_arg(arg: &str, kind: NthKind) -> Result<Nth, SelectError> {
    let arg = normalize(arg);
    let (a, b) = if arg == "odd" {
        (2, 1)
    } else if arg == "even" {
        (2, 0)
    } else if let Some(captures) = nth_ab(&arg) {
        let a = match captures.1 {
            Some(value) => value.parse::<i64>().map_err(|_| bad_nth(&arg))?,
            None => 1,
        };
        let b = match captures.2 {
            Some(value) => value.trim().parse::<i64>().map_err(|_| bad_nth(&arg))?,
            None => 0,
        };
        (a, b)
    } else if let Some(value) = nth_b(&arg) {
        (0, value.parse::<i64>().map_err(|_| bad_nth(&arg))?)
    } else {
        return Err(bad_nth(&arg));
    };
    Ok(match kind {
        NthKind::Child => Nth::Child { a, b },
        NthKind::LastChild => Nth::LastChild { a, b },
        NthKind::OfType => Nth::OfType { a, b },
        NthKind::LastOfType => Nth::LastOfType { a, b },
    })
}

fn bad_nth(arg: &str) -> SelectError {
    SelectError::new(format!("Could not parse nth-index '{}': unexpected format", arg))
}

/// jsoup `NTH_AB`: `(([+-])?(\d+)?)n(\s*([+-])?\s*\d+)?`.
fn nth_ab(arg: &str) -> Option<(String, Option<String>, Option<String>)> {
    let bytes: Vec<char> = arg.chars().collect();
    let mut index = 0;
    let mut sign = String::new();
    if index < bytes.len() && (bytes[index] == '+' || bytes[index] == '-') {
        sign.push(bytes[index]);
        index += 1;
    }
    let digits_start = index;
    while index < bytes.len() && bytes[index].is_ascii_digit() {
        index += 1;
    }
    let digits: String = bytes[digits_start..index].iter().collect();
    if index >= bytes.len() || bytes[index] != 'n' {
        return None;
    }
    index += 1;
    let rest: String = bytes[index..].iter().collect();
    let rest = rest.trim();
    if rest.is_empty() {
        let a = if digits.is_empty() { None } else { Some(format!("{}{}", sign, digits)) };
        return Some((arg.to_string(), a, None));
    }
    let (b, valid) = if let Some(rest) = rest.strip_prefix('+') {
        (rest.trim().to_string(), true)
    } else if let Some(rest) = rest.strip_prefix('-') {
        (format!("-{}", rest.trim()), true)
    } else {
        (rest.to_string(), false)
    };
    if !valid || b.is_empty() || !b.trim_start_matches('-').chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let a = if digits.is_empty() { None } else { Some(format!("{}{}", sign, digits)) };
    Some((arg.to_string(), a, Some(b)))
}

/// jsoup `NTH_B`: `([+-])?(\d+)`.
fn nth_b(arg: &str) -> Option<String> {
    let trimmed = arg.trim();
    let mut chars = trimmed.chars();
    let first = chars.next()?;
    let rest: String = chars.collect();
    if first == '+' || first == '-' {
        if rest.is_empty() || !rest.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        return Some(format!("{}{}", if first == '+' { "" } else { "-" }, rest));
    }
    if trimmed.chars().all(|c| c.is_ascii_digit()) {
        return Some(trimmed.to_string());
    }
    None
}

fn pseudo_argument(raw: String, name: &str) -> Result<String, SelectError> {
    let text = unescape(&raw);
    if text.is_empty() {
        return Err(SelectError::new(format!("{}(text) query must not be empty", name)));
    }
    Ok(text)
}

/// jsoup `ContainsText`/`ContainsOwnText`: `lowerCase(normaliseWhitespace(text))`.
fn lower_normalised(value: String) -> String {
    normalise_whitespace(&value).to_lowercase()
}

fn compile_regex(raw: &str, name: &str) -> Result<Regex, SelectError> {
    if raw.is_empty() {
        return Err(SelectError::new(format!("{}(regex) query must not be empty", name)));
    }
    Regex::new(raw).map_err(|error| SelectError::new(format!("Pattern syntax error: {} ({})", raw, error)))
}

/// jsoup `AttributeKeyPair`: quotes stripped, values normalised (lower case,
/// trimmed) unless the value was quoted, in which case it is only lower-cased.
fn attribute_value(raw: String, trim_value: bool) -> Result<String, SelectError> {
    let value = attribute_value_raw(raw, trim_value);
    if value.is_empty() {
        return Err(SelectError::new("String must not be empty"));
    }
    Ok(value)
}

fn attribute_value_raw(raw: String, trim_value: bool) -> String {
    let is_string_literal = (raw.starts_with('\'') && raw.ends_with('\'') && raw.len() >= 2)
        || (raw.starts_with('"') && raw.ends_with('"') && raw.len() >= 2);
    let value = if is_string_literal { raw[1..raw.len() - 1].to_string() } else { raw };
    if !trim_value && is_string_literal {
        value.to_lowercase()
    } else {
        normalize(&value)
    }
}

fn normalize(value: &str) -> String {
    value.to_lowercase().trim().to_string()
}

/// jsoup `TokenQueue.unescape`.
fn unescape(value: &str) -> String {
    let mut out = String::new();
    let mut last = '\0';
    for mut c in value.chars() {
        if c == '\\' {
            if last == '\\' {
                out.push(c);
                c = '\0';
            }
        } else {
            out.push(c);
        }
        last = c;
    }
    out
}

/// jsoup `StringUtil.normaliseWhitespace` is used by `:contains` preparsing.
pub fn normalise_search_text(value: &str) -> String {
    normalise_whitespace(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(dom: &Dom, query: &str) -> Vec<String> {
        select(dom, 0, query)
            .expect("selector parses")
            .into_iter()
            .map(|id| dom.id_attr(id).to_string())
            .collect()
    }

    const DOC: &str = r#"
        <div id="list"><a id="a1" href="/c1">第一章</a><a id="a2" href="/c2">第二章</a></div>
        <div id="body" class="con"><p id="p1">A&nbsp; B</p><p id="p2">中文😀</p><p id="p3"></p></div>
        <ul id="u"><li id="l1">x</li><li id="l2">y</li><li id="l3">z</li></ul>
    "#;

    #[test]
    fn basic_selectors_and_case() {
        let dom = Dom::parse(DOC);
        assert_eq!(ids(&dom, "#list a"), vec!["a1", "a2"]);
        assert_eq!(ids(&dom, "div > a"), vec!["a1", "a2"]);
        assert_eq!(ids(&dom, "DIV#body p"), vec!["p1", "p2", "p3"]);
        assert_eq!(ids(&dom, "[href^=/c2]"), vec!["a2"]);
        assert_eq!(ids(&dom, "a[href$='2']"), vec!["a2"]);
        assert_eq!(ids(&dom, "a[href*=\"c\"]"), vec!["a1", "a2"]);
        assert_eq!(ids(&dom, ":root").len(), 1);
    }

    #[test]
    fn jsoup_extensions_match_the_frozen_source() {
        let dom = Dom::parse(DOC);
        assert_eq!(ids(&dom, "#u li:eq(1)"), vec!["l2"]);
        assert_eq!(ids(&dom, "#u li:lt(2)"), vec!["l1", "l2"]);
        assert_eq!(ids(&dom, "#u li:gt(1)"), vec!["l3"]);
        assert_eq!(ids(&dom, "#u li:nth-child(2)"), vec!["l2"]);
        assert_eq!(ids(&dom, "#u li:nth-child(2n+1)"), vec!["l1", "l3"]);
        assert_eq!(ids(&dom, "#u li:nth-last-child(1)"), vec!["l3"]);
        assert_eq!(ids(&dom, "#list a:contains(第二)"), vec!["a2"]);
        assert_eq!(ids(&dom, "#list a:matchesOwn(^第二章$)"), vec!["a2"]);
        assert_eq!(ids(&dom, "div:has(#p2)"), vec!["body"]);
        assert_eq!(ids(&dom, "#list a:not(#a1)"), vec!["a2"]);
        assert_eq!(ids(&dom, "p:empty"), vec!["p3"]);
        assert_eq!(ids(&dom, "#u > li:first-child"), vec!["l1"]);
        assert_eq!(ids(&dom, "#u > li:last-child"), vec!["l3"]);
        assert_eq!(ids(&dom, "#u > li:only-child"), Vec::<String>::new());
    }

    #[test]
    fn contains_normalises_and_lower_cases_its_argument() {
        let dom = Dom::parse(DOC);
        assert_eq!(ids_from(&dom, 0, "p:contains(A   B)"), vec!["p1"]);
        assert_eq!(ids_from(&dom, 0, "p:contains(a b)"), vec!["p1"]);
    }

    #[test]
    fn context_element_is_included_like_element_select() {
        let dom = Dom::parse(DOC);
        let list = collect(&dom, 0, &parse("#list").unwrap())[0];
        assert_eq!(ids_from(&dom, list, "div"), vec!["list"]);
    }

    fn ids_from(dom: &Dom, root: NodeId, query: &str) -> Vec<String> {
        select(dom, root, query)
            .expect("selector parses")
            .into_iter()
            .map(|id| dom.id_attr(id).to_string())
            .collect()
    }

    #[test]
    fn unsupported_pseudo_class_is_rejected() {
        let dom = Dom::parse(DOC);
        let error = select(&dom, 0, "a:matchText").unwrap_err();
        assert!(error.message.contains(":matchText"), "{}", error.message);
    }
}
