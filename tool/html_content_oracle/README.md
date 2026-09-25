# Content-HTML oracle (host JVM, #101)

The frozen web-book content stage turns one page's rule value into text before
any reader or `ContentProcessor` sees it. The deciding line is
`app/src/main/java/io/legado/app/model/webBook/BookContent.kt:178`:

```kotlin
var content = analyzeRule.getString(contentRule.content, unescape = false)
content = HtmlFormatter.formatKeepImg(content, rUrl)
if (content.indexOf('&') > -1) {
    content = StringEscapeUtils.unescapeHtml4(content)
}
```

`HtmlFormatter.formatKeepImg` is `format(html, notImgHtmlRegex)` followed by an
image pass that rewrites a matched `<img>`'s `src` to an absolute address, and
`format` is a fixed expression chain (`HtmlFormatter.kt:20-34`): fold `&nbsp;`
runs, `&ensp;`/`&emsp;` to one space, remove `&thinsp;`/`&zwnj;`/`&zwj;` and their
literal forms, turn the `div`/`p`/`br`/`hr`/`h\d`/`article`/`dd`/`dl` family into
a paragraph break, drop comments, drop every other tag, then indent every
paragraph. A source whose `ruleContent.content` ends in `@html` therefore hands
this stage HTML *by design* — the field is jsoup's `Elements.outerHtml()` — and
the reader never shows a tag the frozen did not intend to show.

This oracle executes that call, and the two lines after it, over a fixed corpus
and records the exact output string: `evidence/jvm-host/golden.json`, one row per
case with the formatter's own text and the text the frozen stores after the
unescape. `test/content_html_differential_test.dart` runs the product's ported
pass (`formatChapterContent`, `lib/source/book_source_pipeline.dart`) over the
same inputs and compares byte for byte.

This is **not** the four-stage device oracle. The frozen side of the differential
contract is a golden produced by the hash-pinned frozen APK on a device
(`tool/first_slice/`, `tool/nested_oracle/`). Here the frozen bytes are executed
in the host JVM instead, which is enough for a pure formatter but is recorded as
a host-JVM source execution, not a device golden. The Android row stays
`not-run`; `evidence/jvm-host/manifest.json` states the same.

Files:

- `fixtures.json` — the corpus: the marker shapes the frozen chain branches on
  (each `<br>` spelling, the whole wrap family, a meaningless tag, an
  `<image>`/`<imgs>` look-alike, a self-closing non-wrap tag, a comment with and
  without a `>`, the entity families, a page whose tags were escaped, blank and
  CRLF lines, a markup-only page, images with and without a base URL, and the
  two JSON-shaped page values), plus the operator's own page shape.
- `HtmlContentOracle.kt` — the harness: verifies every frozen source's sha1
  against the corpus pins, verifies each transcription against the frozen file,
  runs `formatKeepImg` + the unescape for every case twice and refuses a case
  whose two runs differ, then writes `golden.json` and `manifest.json`.
- `FrozenContentStubs.kt`, `FrozenAnalyzeUrlStub.kt` — the compile-classpath
  members `HtmlFormatter.kt` reaches but whose own files import
  OkHttp/hutool/Room and cannot be compiled on a desktop JVM:
  `NetworkUtils.getAbsoluteURL` (image pass), `StringExtensions.isAbsUrl` /
  `isDataUrl` and `AnalyzeUrl.paramPattern` (templated image `src`). Each is
  transcribed from the frozen body and checked at run time; the manifest names
  them under `transcription`.
- `frozen.sha1` — the frozen files the golden is labelled with. `run_golden.sh`
  refuses a checkout that does not match, and the harness re-verifies every
  hash before writing.
- `jars.sha256` — the pin for the two Apache Commons jars the harness fetches
  (`commons-text` 1.13.0, the frozen revision's own, and the `commons-lang3`
  it needs). The frozen unescape is `StringEscapeUtils.unescapeHtml4`; a
  hand-written entity table is not the frozen behaviour. `jars/` is fetched, not
  committed (`.gitignore`).
- `run_golden.sh` — resolves the Kotlin compiler, kotlin-stdlib and Gson from
  the Gradle cache (no `kotlinc` is on `PATH`), fetches and verifies the Commons
  jars, compiles the frozen `HtmlFormatter.kt` and `AppPattern.kt` with the
  harness, and runs it.
- `evidence/jvm-host/golden.json` and `manifest.json` — the rows and their
  provenance (frozen revision, source sha1s, toolchain versions, determinism and
  transcription notes, the `not-run` device row).

Reproduce:

```
bash tool/html_content_oracle/run_golden.sh
```

## What the corpus decides

- The frozen **keeps** `<img>` (and only it: `(?!img)` is a first-three-letters
  test, so `<image src="x">` is dropped like any other meaningless tag while
  `<imgs src="y">` survives and is rewritten), and it **keeps** a tag whose name
  is followed by neither a space nor `>` (`<span/>`).
- The frozen **turns into a paragraph break** `div`, `p`, `br` (every spelling),
  `hr`, `h\d`, `article`, `dd`, `dl`; **drops** every other tag with no break;
  **drops** a comment (`<!--[^>]*-->`, which cannot cross a `>`); **folds**
  `&nbsp;` runs and `&ensp;`/`&emsp;` to one space; **removes**
  `&thinsp;`/`&zwnj;`/`&zwj;`; then **indents** each paragraph (`　　` at the
  start and after every break, the trailing run removed).
- A page that wrote its tags **escaped** (`&lt;p&gt;`) shows them as text: the
  formatter sees no `<` and the frozen's unescape runs after it. That is the one
  way this stage shows a tag, and it is the reason the corpus has an
  `escaped-tags` row.

## What this fixture does not cover

- The device golden: the frozen's own `BookContent.analyzeContent` inside the
  installed APK (`not-run`, owned by #101).
- The image half: the frozen rewrites a kept `<img>`'s `src` to an absolute
  address through `NetworkUtils.getAbsoluteURL`; the corpus records that
  (`image-absolute-base`, `img-prefix-tags`) and the product deliberately
  answers the source's own address, resolving it against the chapter's URL when
  it fetches the image (#67).
- The rule read that produces the input: every case begins at
  `getString(ruleContent.content, unescape = false)`. This product's rule read
  has already unescaped once (`HtmlRuleBatch.documentText`), so the frozen's
  entity branches fire only for a rule value that still carries the entity text
  (a `@js:` segment's value). The `unescape-order` rows pin both sides' answers;
  the read's own `unescape = false` form is #104.
- `ContentProcessor.getContent` and the reader's `TextChapter`: they run after
  this stage, and they are pinned by `tool/re_segment_oracle/`,
  `tool/replace_rule_oracle/` and `test/content_processing_test.dart`.
