# The HTML rule adapter is written in Rust

**Status:** accepted (2026-09-15)

**One adapter, in Rust.** The frozen selector semantics are jsoup's plus Legado's rule layer
(ADR 0005), so the product needs one explicit adapter rather than the standard-library
approximations. That adapter is a Rust crate: `packages/fjs/liber_html` holds an arena DOM
over `html5ever`, a port of jsoup 1.16.2's selector engine (`QueryParser`, `Evaluator`,
`StructuralEvaluator`, `CombiningEvaluator`, `Collector`), jsoup's text and serialization
semantics, and a port of Legado's rule layer (`AnalyzeByJSoup.kt`: `@CSS:`/legacy modes, `@`
chains, `&&`/`||`/`%%` merges, the `ElementsSingle` index syntax, `getResultLast`'s
extraction switch, and `AnalyzeRule.kt`'s `##` replacement).

**One native build.** The crate is a path dependency of `packages/fjs/libfjs`, so it rides the
build `fjs` already proves: one `cargokit` integration, one library per platform, one
`flutter_rust_bridge` 2.12.0 pair. Adding a second Rust plugin would have duplicated the
build, the platform glue and the codegen for no separation the module boundary does not
already give. `liber_html` stays independently testable (`cargo test` in the crate) because
its tests do not link the JavaScript runtime.

**Whole documents cross the boundary.** One call takes a fetched page plus every rule of one
pipeline stage and returns the results together, which is the frozen `AnalyzeByJSoup` shape:
one tree, many rules. A call per selector would marshal the document once per rule, and the
marshalling cost would eat the gain the move to Rust is for. Jobs name their context: the
document, or the matches of an earlier `Elements` job, so a stage's per-element extractions
stay inside the same call.

**The call is synchronous.** The Dart layer this replaces parsed and selected on the UI
isolate, so nothing regressed by keeping the work there; a synchronous boundary also keeps
the pipeline free of a second asynchronous hop and lets widget tests drive it. Moving the
call to a worker thread stays open if profiling shows a page large enough to matter.

## Considered options

- **A Dart adapter over another HTML package.** Rejected by ADR 0005's probe: `:nth-child`
  off by one, `:eq`/`:contains` unsupported, attribute comparison and result order
  differences, and unusable tolerant-HTML XPath — exactly the divergences real sources
  depend on.
- **Trusting the parser to match jsoup.** Rejected: jsoup's selectors are not standard CSS
  (`:lt`/`:gt`/`:eq` index siblings, `:nth-last-child` counts without the CSS `+ 1`,
  `:contains` lower-cases both sides, attributes compare case-insensitively, `:has`
  evaluates with the subject as root), and its pretty printer is part of the `html`/`all`
  output. The port follows the Java source operation by operation.
- **A second Rust plugin package with its own `cargokit` build.** Rejected: it doubles the
  native build and the loader path for one more library, and the existing library already
  loads wherever the JavaScript runtime does.
- **A hand-written C ABI instead of `flutter_rust_bridge`.** Rejected: it is a second
  mechanism next to the one the product already ships, with its own marshalling, lifetime and
  codegen problems.
- **Approximating the rule families that belong to other tickets.** Rejected: rule
  JavaScript and templates (#3), XPath, JSON rules and `$1` captures now fail with an
  explicit unsupported error, the way the frozen reader fails on a rule it cannot evaluate,
  instead of returning a value no frozen row would confirm.

## Consequences

`lib/source/html_source_pipeline.dart` now declares each stage's rules as one
`HtmlRuleBatch` (`lib/source/html_rule_adapter.dart`), and the old rule layer with its
`text`/`textNodes`/`href`/`src` whitelist is gone, so `ownText`, `html`, `all` and every
attribute name are reachable. `tool/html_oracle/fixtures.json` carries 28 rows for
the extraction and selector families, and `tool/html_adapter_gate.dart` runs them through the
adapter in CI; those rows are compared against values read from the frozen source until a
device run produces the frozen golden, so they stay `not-run` in
`docs/compatibility/book-source-capability-matrix.md` rather than becoming a compatibility
claim. The adapter is also the seam the later families plug into: a family that is ported
turns a failing row into a passing one without touching the pipeline.

Provenance: ticket #12, with jsoup 1.16.2 and the frozen commit
`14dd24945b2914ce2708b8abaa4ee67ceef892af` read as the reference.
