//! Liber's HTML rule adapter: the frozen reader's Jsoup semantics behind one
//! boundary.
//!
//! The frozen Book Source pipeline evaluates HTML rules with jsoup plus Legado's
//! own rule layer. This crate reproduces that layered behaviour - document
//! parsing, jsoup selectors, `@` chains, `&&`/`||`/`%%` merges, index and slice
//! positioning, and result extraction - so the product can call one adapter
//! instead of approximating the semantics with a different HTML library.
//!
//! The boundary takes a whole document plus every rule of one pipeline stage and
//! returns the results together: one call per fetched page, never one call per
//! selector.

pub mod dom;
pub mod entity;
pub mod rule;
pub mod selector;
pub mod serialize;

pub use dom::{Dom, NodeId};

use std::collections::{HashMap, HashSet};

/// What a job returns: matched elements (only their count leaves the adapter),
/// one extracted string per context element, or the extracted values as a list.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum JobOutput {
    Elements,
    Text,
    /// The frozen `AnalyzeRule.getStringList` answer: the rule's matches, one
    /// value each, with the `##` field applied per value and no entity unescape.
    TextList,
    /// Elements.select(raw CSS): stable identity dedup across the parent vector.
    CollectionCssSelect,
    /// First present attribute, including empty/blank values, without shaping.
    RawAttribute,
}

#[derive(Debug, Clone)]
pub struct JobSpec {
    pub id: String,
    pub rule: String,
    /// The id of an earlier `Elements` job whose matches are this job's contexts.
    /// `None` means the document itself, as the frozen `AnalyzeByJSoup(doc)`.
    pub parent: Option<String>,
    /// Zero-based position in the completed parent's final selection vector.
    /// None retains all contexts; Some requires an existing Elements parent.
    pub parent_index: Option<i32>,
    pub output: JobOutput,
}

#[derive(Debug, Clone)]
pub struct JobFailure {
    pub kind: String,
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct JobOutcome {
    pub id: String,
    /// Number of element matches, or the number of extracted values for a
    /// `Text`/`TextList` job before replacement (zero when its rule did not
    /// match; a `TextList` job's count is the length of its `values`).
    pub count: usize,
    /// One value per context for `Text` jobs; every matched value for a
    /// `TextList` job.
    pub values: Vec<String>,
    pub failure: Option<JobFailure>,
}

#[derive(Debug, Clone, Default)]
pub struct Analysis {
    pub jobs: Vec<JobOutcome>,
}

/// Runs one stage's jobs against one document.
pub fn analyze(html: &str, jobs: &[JobSpec]) -> Analysis {
    let dom = Dom::parse(html);
    let mut elements: HashMap<String, Vec<NodeId>> = HashMap::new();
    let mut outcomes = Vec::with_capacity(jobs.len());
    for job in jobs {
        let context: Vec<NodeId> = if let Some(index) = job.parent_index {
            let selected = job.parent.as_ref().and_then(|parent| elements.get(parent))
                .and_then(|found| usize::try_from(index).ok().and_then(|index| found.get(index)))
                .copied();
            match selected {
                Some(node) => vec![node],
                None => {
                    outcomes.push(JobOutcome {
                        id: job.id.clone(), count: 0, values: Vec::new(),
                        failure: Some(JobFailure {
                            kind: "unsupported".to_string(),
                            message: format!("parentIndex 必须引用已完成的 Elements 父任务中的有效索引：{}", index),
                        }),
                    });
                    continue;
                }
            }
        } else {
            match &job.parent {
            None => vec![0],
            Some(parent) => match elements.get(parent) {
                Some(found) => found.clone(),
                None => {
                    outcomes.push(JobOutcome {
                        id: job.id.clone(),
                        count: 0,
                        values: Vec::new(),
                        failure: Some(JobFailure {
                            kind: "runtime".to_string(),
                            message: format!("规则任务引用了未知的父任务：{}", parent),
                        }),
                    });
                    continue;
                }
            },
            }
        };
        let outcome = match job.output {
            JobOutput::Elements => {
                let mut matched: Vec<NodeId> = Vec::new();
                let mut failure = None;
                for node in &context {
                    match rule::elements(&dom, *node, &job.rule) {
                        Ok(found) => matched.extend(found),
                        Err(error) => {
                            failure = Some(failure_of(error));
                            break;
                        }
                    }
                }
                if failure.is_none() {
                    elements.insert(job.id.clone(), matched.clone());
                }
                JobOutcome {
                    id: job.id.clone(),
                    count: if failure.is_some() { 0 } else { matched.len() },
                    values: Vec::new(),
                    failure,
                }
            }
            JobOutput::CollectionCssSelect => {
                // Parse even when there are no roots: Elements.select validates
                // CSS before traversing its iterable of contexts.
                match selector::parse(&job.rule) {
                    Ok(evaluator) => {
                        let mut seen = HashSet::new();
                        let mut matched = Vec::new();
                        for node in &context {
                            for found in selector::collect(&dom, *node, &evaluator) {
                                if seen.insert(found) {
                                    matched.push(found);
                                }
                            }
                        }
                        let count = matched.len();
                        elements.insert(job.id.clone(), matched);
                        JobOutcome {
                            id: job.id.clone(), count, values: Vec::new(), failure: None,
                        }
                    }
                    Err(error) => JobOutcome {
                        id: job.id.clone(), count: 0, values: Vec::new(),
                        failure: Some(JobFailure {
                            kind: "parse".to_string(), message: error.message,
                        }),
                    },
                }
            }
            JobOutput::RawAttribute => {
                let value = context.iter().find_map(|node| dom.attr(*node, &job.rule));
                JobOutcome {
                    id: job.id.clone(), count: usize::from(value.is_some()),
                    values: value.into_iter().map(str::to_owned).collect(), failure: None,
                }
            }
            JobOutput::Text | JobOutput::TextList => {
                let mut values = Vec::new();
                let mut count = 0;
                let mut failure = None;
                for node in &context {
                    let extracted = match job.output {
                        JobOutput::TextList => rule::string_list_with_count(&dom, *node, &job.rule),
                        _ => rule::string_with_count(&dom, *node, &job.rule)
                            .map(|(value, matched)| (vec![value], matched)),
                    };
                    match extracted {
                        Ok((found, matched)) => {
                            values.extend(found);
                            count += matched;
                        }
                        Err(error) => {
                            failure = Some(failure_of(error));
                            break;
                        }
                    }
                }
                JobOutcome {
                    id: job.id.clone(),
                    count: if failure.is_some() { 0 } else { count },
                    values: if failure.is_some() { Vec::new() } else { values },
                    failure,
                }
            }
        };
        outcomes.push(outcome);
    }
    Analysis { jobs: outcomes }
}

fn failure_of(error: rule::RuleError) -> JobFailure {
    JobFailure {
        kind: match error.kind {
            rule::RuleErrorKind::Unsupported => "unsupported",
            rule::RuleErrorKind::Parse => "parse",
            rule::RuleErrorKind::Runtime => "runtime",
        }
        .to_string(),
        message: error.message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(id: &str, rule: &str, parent: Option<&str>, output: JobOutput) -> JobSpec {
        JobSpec {
            id: id.to_string(), rule: rule.to_string(), parent: parent.map(str::to_owned),
            parent_index: None, output,
        }
    }

    #[test]
    fn collection_css_select_deduplicates_identity_in_first_seen_order() {
        let result = analyze(
            "<section id=outer><div id=inner><b id=leaf>leaf</b></div></section><div id=last><b id=tail>tail</b></div>",
            &[
                job("roots", "#last&&#outer&&#inner&&#inner", None, JobOutput::Elements),
                job("legacy", "b", Some("roots"), JobOutput::Elements),
                job("selected", "b", Some("roots"), JobOutput::CollectionCssSelect),
                job("ids", "id", Some("selected"), JobOutput::RawAttribute),
                job("text", "@text", Some("selected"), JobOutput::Text),
                JobSpec { parent_index: Some(1), ..job("focus", ":root", Some("selected"), JobOutput::Elements) },
                job("focused_id", "id", Some("focus"), JobOutput::RawAttribute),
            ],
        );
        assert!(result.jobs.iter().all(|job| job.failure.is_none()));
        assert_eq!(result.jobs[0].count, 4); // Ordinary merge keeps duplicate roots.
        assert_eq!(result.jobs[1].count, 4); // Ordinary extraction keeps overlap.
        assert_eq!(result.jobs[2].count, 2);
        assert_eq!(result.jobs[3].values, vec!["tail"]);
        assert_eq!(result.jobs[4].values, vec!["tail", "leaf"]);
        assert_eq!(result.jobs[6].values, vec!["leaf"]);
    }

    #[test]
    fn collection_css_select_validates_css_even_with_empty_roots() {
        let result = analyze("<p>body</p>", &[
            job("roots", ".missing", None, JobOutput::Elements),
            job("empty", "b", Some("roots"), JobOutput::CollectionCssSelect),
            job("invalid", "[", Some("roots"), JobOutput::CollectionCssSelect),
        ]);
        assert_eq!(result.jobs[1].count, 0);
        assert!(result.jobs[1].failure.is_none());
        assert_eq!(result.jobs[2].failure.as_ref().unwrap().kind, "parse");
    }

    #[test]
    fn raw_attribute_distinguishes_missing_from_present_empty() {
        let html = "<div id=missing><i></i><i data-v=later></i></div><div id=empty><i data-v=\"\"></i><i data-v=later></i></div>";
        for (rule, expected) in [("#missing i", vec!["later"]), ("#empty i", vec![""]), (".absent", vec![])] {
            let result = analyze(html, &[
                job("roots", rule, None, JobOutput::Elements),
                job("attr", "data-v", Some("roots"), JobOutput::RawAttribute),
            ]);
            assert!(result.jobs[1].failure.is_none());
            assert_eq!(result.jobs[1].count, expected.len());
            assert_eq!(result.jobs[1].values, expected);
        }
    }

    #[test]
    fn raw_attribute_keeps_observed_units_and_text_all_keys() {
        // Actual collection-attribute-probe-v1 charCodeAt observations: raw
        // whitespace includes CR, and parsed entity text is not unescaped twice.
        let result = analyze(
            "<div id=space data-v=\" &#9;&#10;&#13; \"></div><div id=collision text=\"T&amp;amp;\" all=\"A&amp;amp;\">body</div>",
            &[
                job("space", "#space", None, JobOutput::Elements),
                job("raw", "data-v", Some("space"), JobOutput::RawAttribute),
                job("collision", "#collision", None, JobOutput::Elements),
                job("text_attr", "text", Some("collision"), JobOutput::RawAttribute),
                job("all_attr", "all", Some("collision"), JobOutput::RawAttribute),
                job("text", "@text", Some("collision"), JobOutput::Text),
            ],
        );
        assert!(result.jobs.iter().all(|job| job.failure.is_none()));
        assert_eq!(result.jobs[1].values, vec![" \t\n\r "]);
        assert_eq!(result.jobs[3].values, vec!["T&amp;"]);
        assert_eq!(result.jobs[4].values, vec!["A&amp;"]);
        assert_eq!(result.jobs[5].values, vec!["body"]);
    }

    #[test]
    fn text_job_skips_replacement_when_nothing_matched() {
        let result = analyze("<div>book</div>", &[JobSpec {
            id: "toc".to_string(),
            rule: "class.missing@href##$##/toc".to_string(),
            parent: None,
            parent_index: None,
            output: JobOutput::Text,
        }]);
        assert_eq!(result.jobs[0].values, vec![""]);
        assert_eq!(result.jobs[0].count, 0);
    }

    #[test]
    fn one_document_many_jobs() {
        let html = r#"
            <ul class="list">
              <li><a href="/1">第一章</a></li>
              <li><a href="/2">第二章</a></li>
            </ul>
            <div class="content">正文<em>强调</em></div>
        "#;
        let analysis = analyze(
            html,
            &[
                JobSpec {
                    id: "items".to_string(),
                    rule: ".list li".to_string(),
                    parent: None,
                    parent_index: None,
                    output: JobOutput::Elements,
                },
                JobSpec {
                    id: "names".to_string(),
                    rule: "a@text".to_string(),
                    parent: Some("items".to_string()),
                    parent_index: None,
                    output: JobOutput::Text,
                },
                JobSpec {
                    id: "urls".to_string(),
                    rule: "a@href".to_string(),
                    parent: Some("items".to_string()),
                    parent_index: None,
                    output: JobOutput::Text,
                },
                JobSpec {
                    id: "body".to_string(),
                    rule: ".content@text".to_string(),
                    parent: None,
                    parent_index: None,
                    output: JobOutput::Text,
                },
            ],
        );
        assert_eq!(analysis.jobs[0].count, 2);
        assert_eq!(analysis.jobs[1].values, vec!["第一章", "第二章"]);
        assert_eq!(analysis.jobs[2].values, vec!["/1", "/2"]);
        assert_eq!(analysis.jobs[3].values, vec!["正文强调"]);
        assert!(analysis.jobs.iter().all(|job| job.failure.is_none()));
    }

    #[test]
    fn a_text_list_job_answers_the_per_item_read() {
        let result = analyze(
            "<div id=\"pages\"><a href=\"/p/1\">1</a><a href=\"/p/2\">2</a></div>",
            &[JobSpec {
                id: "next".to_string(),
                rule: "#pages a@href##^/p/##/page/".to_string(),
                parent: None,
                parent_index: None,
                output: JobOutput::TextList,
            }],
        );
        assert_eq!(result.jobs[0].values, vec!["/page/1", "/page/2"]);
        assert_eq!(result.jobs[0].count, 2);
        assert!(result.jobs[0].failure.is_none());
    }

    #[test]
    fn a_failing_rule_reports_its_family() {
        let analysis = analyze(
            "<div>text</div>",
            &[JobSpec {
                id: "x".to_string(),
                rule: "div@js:result".to_string(),
                parent: None,
                parent_index: None,
                output: JobOutput::Text,
            }],
        );
        let failure = analysis.jobs[0].failure.as_ref().expect("failure is reported");
        assert_eq!(failure.kind, "unsupported");
    }
}
