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
dart run tool/html_adapter_gate.dart <fjs library> - <observations.json> [tool/html_oracle/fixtures.json | tool/html_oracle/list-fixtures.json]
```

The fourth positional argument selects the corpus; an existing three-argument
invocation keeps the original `tool/html_oracle/fixtures.json` and its exact
45-case meaning. A corpus is refused before any rule runs when it declares no
cases. The legacy corpus is recognized by its pinned raw bytes
(`e4853a8d5653db658608d5cbc4db6907015e894731fa90ac911f7283cbb20342`), so a
byte-identical copy is still the legacy corpus while a downgraded copy is
unknown and refused. CI runs this gate on Windows, Linux and macOS; Android and
iOS cross-build the native library. Each case runs through the Rust HTML
adapter, the product rule field, or the JSON reader as its `path` declares, and
fails on a typed value difference. The original 39 expectations were read from
the pinned frozen sources; #65's six were filled only after the installed APK
returned them. All 45 rows then matched the frozen report on Windows. The three
JSON cases confirm only the named `@Json:$.missing##$##Fallback` no-match shape,
not the JSONPath grammar.

## Frozen side (executed)

`tool/html_oracle/evidence/android-17-os4.0.0.31/` holds the executed frozen row:
`golden.json` (45 observations), the `gate-report.json` comparison, the
`manifest.json` with the corpus, APK, harness-source and report hashes, and the
`run.log`. Ticket #65 refreshed it in place as a superset of #51: its 39 shared
ids keep their values and six no-match rows are added. The entry is
`tool/nested_oracle/HtmlOracle.java` (`io.liber.oracle.nested.HtmlOracle`), which
loads `io.legado.app.model.analyzeRule.AnalyzeRule` from the installed,
hash-pinned `io.legado.app.debug` (installed bytes `cc99040c…`), calls
`setContent(document, baseUrl)` and the method selected per case. The collector
emits `{"baselineCommit", "entryPoint", "fingerprint", "corpus",
"observations": [{"id", "value"|"error"}]}`. Its nested `corpus` block records
the asset name, measured byte length and raw SHA-256, plus any declared
fixture/version/schema fields. The committed 45-case golden retains its original
envelope and raw bytes; the gate admits it through the byte-pinned legacy corpus.
An empty corpus fails the capture instead of reporting zero observations. The
original #51 run remains in Git history. Re-run the comparison on Windows:

```
dart run tool/html_adapter_gate.dart <fjs library> tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json <out.json>
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

## HTML-LIST-01 preparation (not executed on a handset)

`list-fixtures.json` is the independent nonempty-list family added for #138. It
is `HTML-LIST-01`, corpus version 1, schema 1, at the same pinned baseline and
entry point. The original `fixtures.json`, the committed 45-case golden, its
gate report and its manifest are unchanged; the default invocation above still
reads the original corpus and admits that golden by the same baseline/entry-point
identity check.

The family has 11 cases over three documents:

| id | entry | source-derived expectation |
|---|---|---|
| `html-list-ordered-hrefs` | HTML `getStringList`, `#list li@a@href` | `["/1", "/2", "/3"]` |
| `html-scalar-twin-ordered-hrefs` | HTML `getString`, same rule | `"/1\n/2\n/3"` (the same matches joined) |
| `html-list-declared-order` | HTML `getStringList`, `#list li[2,0,1]@a@href` | `["/3", "/1", "/2"]` |
| `html-list-per-item-replacement` | HTML `getStringList`, `##^/##/page/` | `["/page/1", "/page/2", "/page/3"]` |
| `html-scalar-joined-replacement-twin` | HTML `getString`, same rule | `"/page/1\n/2\n/3"` (`##` runs on the join) |
| `html-list-empty` | HTML `getStringList`, no match | `[]` |
| `html-list-url-empty` | HTML `getStringListUrl`, no match with `##` | `[]` |
| `html-list-entity-no-unescape` | HTML `getStringList`, `#code@text` | `["A&amp;B"]` |
| `html-scalar-entity-twin` | HTML `getString`, same rule | `"A&B"` (the scalar read unescapes last) |
| `json-list-string-names` | JSON `getStringList`, `@Json:$.names[*]` | `["甲", "乙"]` |
| `json-scalar-string-twin` | JSON `getString`, same rule | `"甲\n乙"` |

The expectations are **source-derived, not a device golden**. They were read
from the frozen list entry points (`AnalyzeRule.getStringList`, its URL branch,
`AnalyzeByJSoup.getStringList`, `AnalyzeByJSonPath.getStringList` and
`AnalyzeRule.getString` at the pinned commit) together with the existing product
path: `HtmlRuleBatch.documentTextList` for the per-match HTML list (its `##` runs
per item and it does not entity-unescape), `HtmlRuleBatch.documentText` for the
scalar join, and `JsonSourceRules.list` rendered by `JsonSourceRules.contentText`
for the string-valued JSON sibling. No new evaluator, bridge API or container
form is introduced.

The nonempty `getStringListUrl` form is a named product refusal (`#90`): the
product's URL mode does not carry the analysis' redirect/base URL. Only the
supported empty URL-list result is in the corpus; the gate refuses a nonempty
URL-list row instead of rendering it as a default list.

### Selected corpus in the harness

`tool/nested_oracle/build.ps1` accepts an optional local `-HtmlCorpusPath`. It
changes only the packaged `assets/html-fixtures.json`; every other asset and
harness source is unchanged, so the default build still carries
`tool/html_oracle/fixtures.json`. The collector reads the packaged asset bytes
and writes the measured binding in its report:

```json
"corpus": {
  "asset": "html-fixtures.json",
  "bytes": 3604,
  "sha256": "<SHA-256 of the bytes that were parsed>",
  "fixtureId": "HTML-LIST-01",
  "corpusVersion": 1,
  "schemaVersion": 1
}
```

The hash is computed from the actual asset bytes, never copied from a hash
claimed inside the corpus. `baselineCommit`, `entryPoint` and the device
`fingerprint` stay in the report. A real handset capture of this family is
**not-run** here; building and inspecting the signed APK is preparation, not a
golden.

### Admission contract

For `HTML-LIST-01` the gate requires the collector's actual nested record: the
`corpus` block with `asset: "html-fixtures.json"`, integer `bytes` equal to the
selected corpus bytes, `sha256` equal to the measured raw hash, string
`fixtureId`, typed integer `corpusVersion`/`schemaVersion`, and a nonempty-string
top-level `fingerprint`. Missing fields or mismatched and fractional values in
this binding are refused. Additional top-level fields do not replace the required
nested metadata. Each case must refer to a string-valued document; an empty
string is valid. The legacy corpus is identified by the raw corpus hash above;
its committed golden uses its original top-level baseline/entry-point fields.

Every frozen row must have exactly one outcome, `value` or `error`. A value is
validated against its declared method: scalar methods accept a string or an
explicit null, list methods accept a string list or an explicit null, and
`error` must be a nonempty string. Rows must name exactly the declared unique
ids in any order. Comparison carries the outcome kind as well as the payload, so
a value and an error with the same text cannot compare equal; null is a value,
not an absence, and missing fields are never backfilled.

### Measured boundary and remaining proof

This preparation measures the extraction/list boundary: ordered HTML matches,
the scalar join, per-item versus joined `##`, the empty default/URL list, the
HTML list's no-unescape behavior and the string-valued JSON list. It does not
run the reader or pipeline: actual TOC/next-page page walking, search →
information → TOC → shelf → reader, final title/content/selection/paragraph
processing, imageStyle layout, the real installed-APK golden, handset and
reader acceptance, and any platform claim remain outstanding for the controller
and #138/#133. The `HTML-LIST-01` destination-only run leaves
`frozenGolden: "not-run"`; it is not a compatibility result. The unchanged
45-case legacy comparison remains the executed frozen row it always was.
