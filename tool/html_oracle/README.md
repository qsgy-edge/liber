# HTML rule oracle corpus

`fixtures.json` is the extraction/selector row set the ticket 12 adapter is
measured against: five documents (chapter, table of contents, search result, one
with script/style nodes, one with a double-encoded entity) and one case per
capability - the ordered and bracket index syntax, the
`&&`/`||`/`%%` merges, the legacy `class.`/`tag.`/`text.` sub-syntax, every
extraction operation, and the Jsoup CSS extensions.

## Destination side

```
dart run tool/html_adapter_gate.dart <fjs library> - <observations.json>
```

CI runs this gate on every destination platform. It runs every case through the
Rust adapter, writes the observations, and fails when a value differs from the
case's `expected`. Those expectations were
derived by reading the frozen `AnalyzeByJSoup.kt`, `AnalyzeRule.kt` and jsoup
1.16.2 at `14dd24945b2914ce2708b8abaa4ee67ceef892af`. They are a reading; the
frozen application has since been run against the corpus (Frozen side below), and
34 of the 35 device rows match the adapter while one row disagrees.

## Frozen side (executed)

`tool/html_oracle/evidence/android-17-os4.0.0.31/` holds the executed frozen row:
`golden.json` (35 observations), the `gate-report.json` comparison, the
`manifest.json` with the corpus, APK, harness-source and report hashes, and the
`run.log`. The entry is `tool/nested_oracle/HtmlOracle.java`
(`io.liber.oracle.nested.HtmlOracle`), which loads
`io.legado.app.model.analyzeRule.AnalyzeRule` from the installed, hash-pinned
`io.legado.app.debug` (installed bytes `cc99040c…`), calls
`setContent(html, baseUrl)` and then `getString(rule)` for every case, and writes
`{"baselineCommit", "entryPoint": "AnalyzeRule.getString", "observations":
[{"id", "value"}]}` - the same report shape the nested oracle records. Re-run the
comparison on Windows:

```
dart run tool/html_adapter_gate.dart <fjs library> \r
  tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json <out.json>
```

The comparison passes for 34 of the 35 rows and fails on
`replacement-trailing-field`: the frozen `AnalyzeRule.kt` splits a rule on the
literal `##` and Kotlin's split keeps a trailing empty field, so the rule is a
four-field `replaceFirst`, and the handset returns `忘语先生` where the adapter
returns `作者：忘语先生` (see `manifest.json`). That is a finding for the adapter;
the corpus expectation was not edited. The capability rows the 34 passing cases
cover are device-confirmed in
`docs/compatibility/book-source-capability-matrix.md`; the fourth-field row is
not.
