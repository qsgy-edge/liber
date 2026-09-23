//! # HTML Rule Adapter API
//!
//! The product's single entry to the frozen HTML rule semantics. One call takes
//! a whole document plus every rule of one pipeline stage, and returns the
//! results together: the document crosses the bridge once, never once per
//! selector.
//!
//! The rules themselves are evaluated by the `liber_html` crate, which ports
//! jsoup 1.16.2's selector engine and Legado's rule layer (`AnalyzeByJSoup.kt`)
//! behind this boundary.

use flutter_rust_bridge::frb;
use liber_html::{JobOutput, JobSpec};

/// What one rule job returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HtmlJobOutput {
    /// Matched elements; only their count leaves the adapter, and later jobs use
    /// them as contexts.
    Elements,
    /// One extracted string per context element.
    Text,
}

/// One rule to evaluate against the document.
#[derive(Debug, Clone)]
pub struct HtmlRuleJob {
    /// Caller-chosen id; later jobs reference it as `parent`.
    pub id: String,
    /// The Book Source rule, with the `@CSS:`/legacy mode prefix, the `@` chain,
    /// the merge operators, the index syntax and the `##` replacement included.
    pub rule: String,
    /// An earlier `Elements` job id whose matches are this job's contexts.
    /// `None` means the document itself.
    pub parent: Option<String>,
    /// Whether the job returns element count or extracted strings.
    pub output: HtmlJobOutput,
}

/// A rule that could not be evaluated, with the family it belongs to.
#[derive(Debug, Clone)]
pub struct HtmlJobFailure {
    /// `unsupported`, `parse` or `runtime`.
    pub kind: String,
    /// The rule family message shown to the reader.
    pub message: String,
}

/// The result of one rule job.
#[derive(Debug, Clone)]
pub struct HtmlJobOutcome {
    /// The job id this outcome answers.
    pub id: String,
    /// Matched element count, or extracted string count for `Text` jobs before
    /// replacement (zero when a document rule did not match).
    pub count: u32,
    /// One value per context element for `Text` jobs.
    pub values: Vec<String>,
    /// Set when the rule could not be evaluated; the values are then empty.
    pub failure: Option<HtmlJobFailure>,
}

/// Evaluates every job of one stage against one document.
///
/// The call is synchronous: the Dart side already parsed and selected on the UI
/// isolate before this adapter existed, the work is a few milliseconds per page,
/// and a synchronous boundary keeps the pipeline - and its widget tests - free of
/// a second asynchronous hop. Moving it to a worker thread stays open if
/// profiling shows it.
#[frb(sync)]
pub fn html_analyze(html: String, jobs: Vec<HtmlRuleJob>) -> Vec<HtmlJobOutcome> {
    let specs: Vec<JobSpec> = jobs
        .into_iter()
        .map(|job| JobSpec {
            id: job.id,
            rule: job.rule,
            parent: job.parent,
            output: match job.output {
                HtmlJobOutput::Elements => JobOutput::Elements,
                HtmlJobOutput::Text => JobOutput::Text,
            },
        })
        .collect();
    liber_html::analyze(&html, &specs)
        .jobs
        .into_iter()
        .map(|job| HtmlJobOutcome {
            id: job.id,
            count: job.count as u32,
            values: job.values,
            failure: job.failure.map(|failure| HtmlJobFailure {
                kind: failure.kind,
                message: failure.message,
            }),
        })
        .collect()
}
