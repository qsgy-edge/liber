# FIELDS-01 — the remaining result-field frozen oracle (ticket #41)

One controlled corpus for the seven rule fields that ticket #41 implemented but
never executed on the frozen side: `ruleSearch.intro`, `ruleSearch.lastChapter`,
`ruleSearch.wordCount`, `ruleSearch.checkKeyWord`, `ruleBookInfo.wordCount`,
`ruleBookInfo.canReName` and `ruleContent.title`.

It is deliberately **separate** from SLICE-01 (`tool/first_slice/`): its own
fixture, its own replay port, its own disposable harness package id
(`io.liber.oracle.fields`) and its own evidence directory. Nothing here reads or
rewrites SLICE-01's corpus, golden or comparison, and `tool/nested_oracle/`,
`tool/replace_rule_oracle/`, `tool/html_oracle/` and `tool/first_slice/fixtures.json`
are untouched.

## Files

- `fixtures.json` — the corpus (`FIELDS-01`): five four-stage cases with their
  own Book Source and replay responses, five `checkKeyWord` cases, the global
  response table, the declared request sequence, and the frozen-source blob
  pins. Its bytes are the compared input; changing them needs a new corpus
  version and a new golden.
- `FieldOracle.java` — the frozen side: drives the real
  `io.legado.app.model.webBook.WebBook.searchBookAwait/getBookInfoAwait/getChapterListAwait/getContentAwait`
  by reflection against the installed, hash-pinned `io.legado.app.debug`, serves
  the corpus inside the device process, and observes
  `io.legado.app.data.entities.BookSource.getCheckKeyword`. It writes its report
  after every case, so a host that freezes the process keeps the finished cases.
- `AndroidManifest.xml`, `build.ps1` — the disposable APK, package
  `io.liber.oracle.fields` (instrumentation entry
  `io.liber.oracle.fields.FieldOracle`).
- `capture.py` — installs the APK once, instruments it, pulls the report, and
  writes `golden.json` + `manifest.json`. `--finalize` re-runs only the
  validation over a report a device run already produced.
- `evidence/` — the executed golden, its manifest, and the raw device logs.

## The corpus

Four-stage cases (`cases`), each one search → book information → table of
contents → content:

| Case | What it observes |
|---|---|
| `html-rename-permitted` | `ruleBookInfo.canReName` non-blank, so the detail page replaces the search title and author; two search results, the second exercising the non-numeric `wordCount` passthrough |
| `html-rename-absent` | `canReName` absent: the search title and author survive, while a nonempty detail `wordCount` still replaces the search one |
| `html-blank-rename-empty-author` | `canReName` blank (`"   "`) and an empty search author: the title survives and the empty author is filled from the detail page |
| `html-content-title-blank` | a blank `ruleContent.title` rule leaves the chapter title as the table of contents gave it |
| `json-fields` | the same rows through JSON rules (`$.…` against a JSON response body) |

`checkKeyWord` cases are observed without any request, through the frozen
`BookSource.getCheckKeyword(default)`: `declared` (non-blank wins), `blank` and
`absent` (the caller's fallback wins), and the two non-string values `number`
and `object`.

Observed per case: the search results' `name`/`author`/`intro`/`lastChapter`/
`wordCount`, the detail `name`/`author`/`wordCount`, and the chapter's effective
`title` (the content title replaced it, or the table of contents' own name
stayed) plus its text.

## Destination side

```
dart run tool/result_field_replay.dart <fjs library>
```

writes `evidence/windows-fields-01.liber.json` and fails when the corpus shape is
broken (an undeclared request, a request sequence other than the declared one, or
a case that did not reach all four stages). `test/result_field_corpus_test.dart`
runs the same corpus inside `flutter test test`, so every desktop CI job executes
it.

## Frozen side

```
pwsh tool/result_field_oracle/build.ps1 -OutputDirectory <fresh dir> -JavaHome <jdk 17>
MSYS_NO_PATHCONV=1 python tool/result_field_oracle/capture.py \
  --serial <serial> --apk <fresh dir>/field-oracle.apk \
  --frozen-source <legado checkout> --output <fresh dir in evidence/>
```

`build.ps1` refuses to build when the corpus asset copy differs from
`fixtures.json`; `capture.py` refuses to run when the frozen checkout's HEAD or
any pinned frozen-source blob differs from `fixtures.json`, when the device
fingerprint or the installed baseline APK differs from the pinned values, when
the harness package already exists, when the frozen report disagrees with the
corpus, or when the frozen application's own store (`databases/legado.db*`,
`shared_prefs/local.xml`) changed. MIUI asks the operator to confirm each
install; the first two attempts on this handset were rejected with
`INSTALL_FAILED_USER_RESTRICTED` before the operator confirmed the third.

`capture.py --finalize --asset <build dir>/assets/field-fixtures.json` re-runs the
report and privacy validation over an evidence directory that already holds the
pulled report and its snapshots — the path this run used after its device step
succeeded but the first validation pass was too strict (see
`manifest.json` → `existingDataHashesUnchanged`, `privateFileChanges`,
`frozenAppDataUnchanged`).

## The comparison

```
rm -f tool/result_field_oracle/evidence/android-17-os4.0.0.31/comparison.json
dart run tool/result_field_compare.dart \
  tool/result_field_oracle/evidence/android-17-os4.0.0.31/golden.json \
  tool/result_field_oracle/evidence/windows-fields-01.liber.json \
  tool/result_field_oracle/evidence/android-17-os4.0.0.31/comparison.json
```

Rows `C1` (the corpus ran identically on both sides) and `F1`–`F7` (one per
field). A row passes only when both sides observed the same thing; an unequal
observation is a `fail` with the divergence named, and an observation one side
does not carry is named in `notCompared` with its reason.

**Executed result: 8 pass / 0 fail / 6 notCompared** (the comparator exits 0).
Every row matches; the two observations that needed a word are:

- `F4 ruleSearch.checkKeyWord`. The field is a *check* keyword: the frozen
  readers of it are the source check and the debug page's search box, and the
  search stage never reads it — the product now matches that, because
  `HtmlSourcePipeline.search()` no longer validates the field. Its frozen
  semantics are the parse layer's: `SearchRule.checkKeyWord` is a `String?` read
  by Gson, so a JSON scalar becomes its literal text while the source is parsed
  (`42` → `"42"` — the executed golden's `checkKeyword.number`) and only an
  array or object is refused. `sourceCheckKeyword` is the one reading point and
  reproduces that: a scalar is its string form, `blank`/absent still fall back
  to the caller's default (`BookSource.kt:208-215`), and a structured value is
  refused by name. The `object` case is therefore refused on both sides, and the
  row records both reasons verbatim.
- Two residuals stay named rather than normalized: the refusal happens at use
  (`FormatException` with the field name) where the frozen reader refuses while
  parsing (`JsonSyntaxException: Expected a string but was BEGIN_OBJECT`), and a
  non-canonical number literal loses its spelling — Gson keeps the source text
  (`1e3`, `1.50`), this product's `jsonDecode` sees `1000.0`, `1.5`. Reopen the
  second one only if a used source declares such a literal.
- Everything else matches byte for byte, including the frozen
  `StringUtils.wordCountFormat` rendering (`12001` → `1.2万字`, `23000` →
  `2.3万字`, `约12万字` unchanged) and the `canReName` gate in all four of its
  shapes.

The F4 fix was approved by the controller after this lane reported the frozen
line and a minimal repro; the golden and the harness evidence are unchanged by
it, and only the product side was re-run to reach 8/0/6.

## Coverage gaps

Named, not hidden:

- The `HtmlFormatter.format` entity/tag branches: the corpus' intros carry no
  entity or tag, so the formatter's replacement is a no-op on both sides. #41's
  unit fixture executes that expression; this corpus observes extraction and the
  formatter's application.
- `ruleContent.title` where a **non-blank** rule extracts a blank value: the
  corpus declares a blank rule (the frozen `titleRule.isNullOrBlank()` branch),
  not a rule that yields blank.
- 10000/10001 word-count boundaries and negative or zero values.
- The frozen chapter-persistence side effect of a non-blank `ruleContent.title`
  (`getContentAwait` runs with `needSave=false`).
- No cookie, pagination, redirect, non-2xx, POST, WebView, XPath, rule-level
  JavaScript or replace-rule row: those belong to #15, #2, #11, #22 and #17.
