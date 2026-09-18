# HTML rule oracle corpus

`fixtures.json` is the extraction/selector row set the ticket 12 adapter is
measured against: five documents (chapter, table of contents, search result, one
with script/style nodes, one with a double-encoded entity) and one case per
capability - the ordered and bracket index syntax, the
`&&`/`||`/`%%` merges, the legacy `class.`/`tag.`/`text.` sub-syntax, every
extraction operation, the Jsoup CSS extensions, and (ticket #11) the rule-field
forms `@js:`, `<js>` and `{{...}}`.

A case may carry `"path": "rule"`: its frozen entry point is
`AnalyzeRule.getString` over a rule that carries a script, so the destination
side runs the product's rule-field path (`lib/source/rule_field.dart` in front of
the Rust adapter) instead of the bare adapter, which deliberately refuses those.
The four `rule` cases are the ones ticket #11 added; their expectations are
source reads like every other row here, and their device golden is `not-run`
until ticket #23 records it. `baseUrl` is the value the device entry must pass to
`setContent(html, baseUrl)` - the `{{baseUrl}}` row and the always-null
`{{title}}` row are only meaningful with it.

## Destination side

```
dart run tool/html_adapter_gate.dart <fjs library> - <observations.json>
```

CI runs this gate on every destination platform. It runs every case through the
Rust adapter, writes the observations, and fails when a value differs from the
case's `expected`. Those expectations were
derived by reading the frozen `AnalyzeByJSoup.kt`, `AnalyzeRule.kt` and jsoup
1.16.2 at `14dd24945b2914ce2708b8abaa4ee67ceef892af`. They are a reading, not an
executed row: the frozen application has not been run against this corpus.

## Frozen side (not-run)

The device rows need an Android device with the hash-pinned frozen APK, the same
shape as `tool/nested_oracle`:

1. Extend the oracle APK with an entry that loads
   `io.legado.app.model.analyzeRule.AnalyzeRule` by reflection, calls
   `setContent(html, baseUrl)` and then `getString(rule)` for each case, and
   writes `{"baselineCommit", "entryPoint": "AnalyzeRule.getString",
   "observations": [{"id", "value"}]}` - the same report shape the nested oracle
   records.
2. Run it, pull the report into
   `tool/html_oracle/evidence/android-<fingerprint>/golden.json`.
3. Re-run the gate with that path as the second argument:
   `dart run tool/html_adapter_gate.dart <fjs library> <golden.json> <out.json>`.

Until step 2 has run, every row here is `not-run` in
`docs/compatibility/book-source-capability-matrix.md`; a green gate only means
the adapter matches the frozen rule layer as read from source.
