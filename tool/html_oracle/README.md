# HTML rule oracle corpus

`fixtures.json` is the extraction/selector row set the ticket 12 adapter is
measured against: five HTML documents and one JSON document, with rows for
ordered and bracket indices, `&&`/`||`/`%%` merges, the legacy
`class.`/`tag.`/`text.` sub-syntax, every
extraction operation, the Jsoup CSS extensions, and (ticket #11) the rule-field
forms `@js:`, `<js>` and `{{...}}`. Ticket #65 adds six no-match `##` cases:
ordinary and URL-mode scalar extraction, plus URL-mode list extraction, for
both HTML and JSON.

A case may carry `"path": "rule"`: its frozen entry point is
`AnalyzeRule.getString` over a rule that carries a script, so the destination
side runs the product's rule-field path (`lib/source/rule_field.dart` in front of
the Rust adapter) instead of the bare adapter, which deliberately refuses those.
The four `rule` cases are the ones ticket #11 added; their expectations are
source reads like every other row here, and ticket #51 recorded their device
golden with the rest of the corpus. `baseUrl` is the value the device entry
passes to `setContent(html, baseUrl)` - the `{{baseUrl}}` row and the always-null
`{{title}}` row are only meaningful with it. The six #65 rows select the frozen
`getString` or `getStringList` overload with their optional `method` field;
`getStringUrl`/`getStringListUrl` pass `isUrl=true`. `path: json` runs the
product's JSON rule reader. The list rows compare typed JSON arrays, not their
string rendering.

## Destination side

```
dart run tool/html_adapter_gate.dart <fjs library> - <observations.json>
```

CI runs this gate on Windows, Linux and macOS; Android and iOS cross-build the
native library. Each case runs through the Rust HTML adapter, the product rule
field, or the JSON reader as its `path` declares, and fails on a typed value
difference. The original 39 expectations were read from the pinned frozen
sources; #65's six were filled only after the installed APK returned them.
All 45 rows then matched the frozen report on Windows. The three JSON cases
confirm only the named `@Json:$.missing##$##Fallback` no-match shape, not the
JSONPath grammar.

## Frozen side (executed)

`tool/html_oracle/evidence/android-17-os4.0.0.31/` holds the executed frozen row:
`golden.json` (45 observations), the `gate-report.json` comparison, the
`manifest.json` with the corpus, APK, harness-source and report hashes, and the
`run.log`. Ticket #65 refreshed it in place as a superset of #51: its 39 shared
ids keep their values and six no-match rows are added. The entry is
`tool/nested_oracle/HtmlOracle.java` (`io.liber.oracle.nested.HtmlOracle`), which
loads `io.legado.app.model.analyzeRule.AnalyzeRule` from the installed,
hash-pinned `io.legado.app.debug` (installed bytes `cc99040c…`), calls
`setContent(document, baseUrl)` and the method selected per case, and writes
`{"baselineCommit", "entryPoint", "observations": [{"id", "value"}]}`. The
original #51 run remains in Git history. Re-run the comparison on Windows:

```
dart run tool/html_adapter_gate.dart <fjs library> \r
  tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json <out.json>
```

The comparison passes for all 45 rows. With an unmatched HTML selector,
`getString` returns `""` but `getString(..., isUrl=true)` applies the `##`
replacement to its empty URL value; `getStringList(..., isUrl=true)` returns
`[]`. JSON's missing-path rule returns `Fallback` in either scalar mode and `[]`
in list mode. The product preserves this distinction without a bridge API
change. The frozen `SourceRule.makeUpRule` splits
a rule on the literal `##` with Kotlin's `split("##")` (`AnalyzeRule.kt:686`),
whose default `limit` of zero keeps the trailing empty field, so `a##b##` is a
four-field frozen `replaceFirst` and `AnalyzeRule.replaceRegex`
(`AnalyzeRule.kt:426-437`) answers with the replaced match only. The adapter
split the same rule the Java way in both `packages/fjs/liber_html/src/rule.rs`
and `lib/source/rule_field.dart`; ticket #51 removed both trailing-empty trims
and corrected the corpus expectation for `replacement-trailing-field`, which had
been read from the Java-style split. The named device-confirmed rows are
recorded in `docs/compatibility/book-source-capability-matrix.md`.
