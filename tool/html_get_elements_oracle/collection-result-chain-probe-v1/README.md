# Controller collection-result chain observations

Five raw files are byte-exact copies of the controller's existing
`source-checkpoint/collection-result-chain-probe-v1/` input/output/receipt/logs.
`pins.json` binds them. This worker did not rerun that JVM or any earlier corpus.
The original main/classes/JARs produced three rows with exit 0; output retains
its hardcoded HTML-GET-ELEMENTS-01 name.

The actual values are `[0, ""]`, `[0, ""]`, and
`[6, "A one B two C three A one B two C three"]`. The first two row IDs describe
hypotheses; their names do not turn the zero observations into ancestor-match
claims. The third pins the frozen AnalyzeByJSoup non-Element string/reparse
boundary: whole Elements passed through JS then ordinary extraction preserves
physically duplicated markup. That operation differs from collection.select,
which deduplicates original NodeIds in first-seen order.

`HTML getElements chain count accessor controls` in
`test/html_get_elements_test.dart` adapts only `es.size()` to the existing
façade-array `es.length`, and compares the actual saved values. These are three
equivalent count-accessor controls, not exact-script Java container parity. No
new size/Java mutation method is introduced. A separate identity test binds the
copied raw bytes; existing 42 test definitions and all observed outputs remain
unchanged.

This is an unverified source checkpoint. Isolated native adapter units and
FRB 2.12.0 generation are recorded externally; Dart/runtime verification needs
a new matching FJS DLL. The previous bundle must not be used with the appended
output enum. Controller owns matching build, actual MCP green, adjacent
regressions, independent review, integrated Windows scratch and platform gates.
