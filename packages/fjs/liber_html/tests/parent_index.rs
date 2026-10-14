//! Source-stage regressions, not executed here. Value cases reuse the retained
//! read-context oracle's p4 CSS/reorder/merge/static-kind rows. Node identity
//! checks are structural adapter invariants, not new frozen parity claims.
use liber_html::{analyze, rule, Dom, JobOutput, JobSpec};

const LIST: &str = "<ul class=\"shelf\"><li><a href=\"/one\">one</a></li><li><a href=\"/two\">two</a></li></ul>";
const MERGED: &str = "<div id=\"one\"><ul class=\"shelf\"><li><a href=\"/one\">one</a></li></ul></div><div id=\"two\"><ul class=\"shelf\"><li><a href=\"/two\">two</a></li></ul></div>";
const TABLE: &str = "<table><tbody><tr><td><a href=\"/one\">one</a></td></tr><tr><td><a href=\"/two\">two</a></td></tr></tbody></table>";

fn job(id: &str, rule: &str, parent: Option<&str>, index: Option<i32>, output: JobOutput) -> JobSpec {
    JobSpec { id: id.into(), rule: rule.into(), parent: parent.map(str::to_string), parent_index: index, output }
}

#[test]
fn elements_root_self_preserves_original_node_identity() {
    for (html, selection) in [(LIST, "li"), (TABLE, "tr")] {
        let dom = Dom::parse(html);
        for node in rule::elements(&dom, 0, selection).unwrap() {
            assert!(rule::elements(&dom, node, "").unwrap().is_empty());
            assert_eq!(rule::elements(&dom, node, ":root").unwrap(), vec![node]);
        }
    }
}

#[test]
fn parent_index_addresses_final_css_reorder_and_merge_vectors() {
    for (html, selection, extraction, expected) in [
        (LIST, "@CSS:ul.shelf > li", "@CSS:li:nth-child(2)@text", ["", "two"]),
        (LIST, "li[1,0]", "@CSS:li:nth-child(2)@text", ["two", ""]),
        (MERGED, "#one li&&#two li", "@CSS:ul.shelf > li@text", ["one", "two"]),
    ] {
        let result = analyze(html, &[
            job("items", selection, None, None, JobOutput::Elements),
            job("first", ":root", Some("items"), Some(0), JobOutput::Elements),
            job("second", ":root", Some("items"), Some(1), JobOutput::Elements),
            job("first-value", extraction, Some("first"), None, JobOutput::Text),
            job("second-value", extraction, Some("second"), None, JobOutput::Text),
        ]);
        assert!(result.jobs.iter().all(|job| job.failure.is_none()));
        assert_eq!(result.jobs[1].count, 1);
        assert_eq!(result.jobs[2].count, 1);
        assert_eq!(result.jobs[3].values, vec![expected[0]]);
        assert_eq!(result.jobs[4].values, vec![expected[1]]);
    }
}

#[test]
fn parent_index_keeps_table_serialization_and_original_sibling_position() {
    let result = analyze(TABLE, &[
        job("rows", "tr", None, None, JobOutput::Elements),
        job("first", ":root", Some("rows"), Some(0), JobOutput::Elements),
        job("second", ":root", Some("rows"), Some(1), JobOutput::Elements),
        job("html-first", "@all", Some("first"), None, JobOutput::TextList),
        job("html-second", "@all", Some("second"), None, JobOutput::TextList),
    ]);
    assert!(result.jobs.iter().all(|job| job.failure.is_none()));
    // The actual retained table-src-identity oracle checks this exact prefix.
    assert!(result.jobs[3].values[0].starts_with("<tr"));
    assert!(result.jobs[4].values[0].starts_with("<tr"));
    // Compare to the same original DOM's structural selection, without making
    // up another frozen output for this new structural invariant.
    let dom = Dom::parse(TABLE);
    let original = rule::elements(&dom, 0, "tr").unwrap();
    assert_eq!(rule::elements(&dom, original[1], "@CSS:tbody > tr:nth-child(2)").unwrap(), vec![original[1]]);
    assert!(rule::elements(&dom, original[0], "@CSS:tbody > tr:nth-child(2)").unwrap().is_empty());
}

#[test]
fn parent_index_groups_static_lists_by_job_without_flattening() {
    let result = analyze(LIST, &[
        job("items", "li", None, None, JobOutput::Elements),
        job("first", ":root", Some("items"), Some(0), JobOutput::Elements),
        job("second", ":root", Some("items"), Some(1), JobOutput::Elements),
        job("kind-first", "@CSS:li:nth-child(2)@text", Some("first"), None, JobOutput::TextList),
        job("kind-second", "@CSS:li:nth-child(2)@text", Some("second"), None, JobOutput::TextList),
        job("all", "@CSS:li:nth-child(2)@text", Some("items"), None, JobOutput::TextList),
    ]);
    assert!(result.jobs.iter().all(|job| job.failure.is_none()));
    assert!(result.jobs[3].values.is_empty());
    assert_eq!(result.jobs[4].values, vec!["two"]);
    assert_eq!(result.jobs[5].values, vec!["two"]);
}

#[test]
fn parent_index_none_keeps_all_contexts_and_unknown_parent_classification() {
    let result = analyze(LIST, &[
        job("items", "li", None, None, JobOutput::Elements),
        job("text", "a@text", Some("items"), None, JobOutput::Text),
        job("missing", "@text", Some("missing"), None, JobOutput::Text),
    ]);
    assert_eq!(result.jobs[1].values, vec!["one", "two"]);
    assert_eq!(result.jobs[2].failure.as_ref().unwrap().kind, "runtime");
}

#[test]
fn parent_index_refuses_absent_non_element_negative_and_out_of_range_parent() {
    for (parent, index) in [(None, 0), (Some("missing"), 0), (Some("text"), 0), (Some("items"), -1), (Some("items"), 2)] {
        let result = analyze(LIST, &[
            job("items", "li", None, None, JobOutput::Elements),
            job("text", "a@text", Some("items"), None, JobOutput::Text),
            job("invalid", ":root", parent, Some(index), JobOutput::Elements),
        ]);
        let failure = result.jobs[2].failure.as_ref().unwrap();
        assert_eq!(failure.kind, "unsupported");
        assert!(failure.message.contains("parentIndex"));
        assert_eq!(result.jobs[2].count, 0);
        assert!(result.jobs[2].values.is_empty());
    }
}
