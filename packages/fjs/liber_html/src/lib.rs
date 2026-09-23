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

use std::collections::HashMap;

/// What a job returns: matched elements (only their count leaves the adapter),
/// one extracted string per context element, or the extracted values as a list.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum JobOutput {
    Elements,
    Text,
    /// The frozen `AnalyzeRule.getStringList` answer: the rule's matches, one
    /// value each, with the `##` field applied per value and no entity unescape.
    TextList,
}

#[derive(Debug, Clone)]
pub struct JobSpec {
    pub id: String,
    pub rule: String,
    /// The id of an earlier `Elements` job whose matches are this job's contexts.
    /// `None` means the document itself, as the frozen `AnalyzeByJSoup(doc)`.
    pub parent: Option<String>,
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
        let context: Vec<NodeId> = match &job.parent {
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

    #[test]
    fn text_job_skips_replacement_when_nothing_matched() {
        let result = analyze("<div>book</div>", &[JobSpec {
            id: "toc".to_string(),
            rule: "class.missing@href##$##/toc".to_string(),
            parent: None,
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
                    output: JobOutput::Elements,
                },
                JobSpec {
                    id: "names".to_string(),
                    rule: "a@text".to_string(),
                    parent: Some("items".to_string()),
                    output: JobOutput::Text,
                },
                JobSpec {
                    id: "urls".to_string(),
                    rule: "a@href".to_string(),
                    parent: Some("items".to_string()),
                    output: JobOutput::Text,
                },
                JobSpec {
                    id: "body".to_string(),
                    rule: ".content@text".to_string(),
                    parent: None,
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
                output: JobOutput::Text,
            }],
        );
        let failure = analysis.jobs[0].failure.as_ref().expect("failure is reported");
        assert_eq!(failure.kind, "unsupported");
    }
}
