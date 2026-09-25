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

## The replace pass (#106)

The same directory also executes the content stage's *replace pass*, the block
that decides what the chapter text looks like when a source declares
`ruleContent.replaceRegex` (`BookContent.kt:133-142`):

```kotlin
var contentStr = contentList.joinToString("\n")
val replaceRegex = contentRule.replaceRegex
if (!replaceRegex.isNullOrEmpty()) {
    contentStr = contentStr.split(AppPattern.LFRegex).joinToString("\n") { it.trim() }
    contentStr = analyzeRule.getString(replaceRegex, contentStr)
    contentStr = contentStr.split(AppPattern.LFRegex).joinToString("\n") { "　　$it" }
}
```

`analyzeRule.getString(replaceRegex, contentStr)` is the frozen rule path: the
`{{…}}`/`@get:`/`@put:` substitution (`SourceRule.makeUpRule`), the `##` field
split, the JSoup/JS/JSON read of the rule part, `replaceRegex`'s own pattern
replacement, and the `unescape = true` pass on the result. It is the branch the
`html-content-replace-rule` readiness class refused before #106 (5 used sources
of the operator's library: 3 with a `{{…}}` beyond `{{chapter.title}}` inside
the replacement, 2 with a `##` field on the content rule beside a non-empty
replacement — measured by `dart run tool/refusal_shapes.dart --content-replace`).

Files:

- `replace_fixtures.json` — the corpus. One row per measured shape, synthetic
  page text and the frozen's own binding names only; no rule text, source name,
  URL or header value from the backup. Each row declares the page HTML, what the
  frozen selector read answers for it (`pageValues`, an input: jsoup is not
  compiled here), the content field, the replacement field, and the book and
  chapter values the bindings read.
- `ContentReplaceOracle.kt` — the harness: verifies every frozen source's sha1,
  verifies the whole frozen script module's tree pin, verifies each transcription
  against the frozen file, runs every case twice and refuses a case whose two
  runs differ, then writes `evidence/jvm-host/replace-golden.json` and
  `replace-manifest.json`.
- `replace-frozen.sha1` — every frozen file this step compiles, pinned.
- `stubs/` — the compile-classpath members the frozen files name whose own files
  import Room/hutool/OkHttp/Android and cannot be compiled on a desktop JVM.
  Each stub is documented and each refuses by name where the corpus does not
  reach it; the ones the corpus *does* reach are transcribed and verified
  (`MapExtensions.getOrPutLimit`, `StringExtensions.isJson`/`splitNotBlank`/
  `isAbsUrl`/`isDataUrl`, `ThrowableExtensions.stackTraceStr`,
  `SharedJsScope.getScope`'s blank-`jsLib` guard, `AnalyzeUrl.paramPattern`).
  `android.text.TextUtils` carries AOSP's own two-line `isEmpty`, because
  `AnalyzeRule` guards every rule text with it and the Android SDK's stub jar
  answers `RuntimeException("Stub!")`.
- `evidence/jvm-host/replace-golden.json` and `replace-manifest.json` — the rows
  and their provenance.

What is executed as the frozen bytes, not transcribed: `AnalyzeRule.kt`,
`RuleDataInterface.kt`, `AnalyzeByRegex.kt`, `HtmlFormatter.kt`, `AppPattern.kt`
and the whole frozen `modules/rhino` script engine, over the revision's own
**Rhino 1.8.0** (`gradle/libs.versions.toml:40`, fetched from Maven Central and
pinned in `jars.sha256`). The `{{…}}` substitutions in the corpus are therefore
evaluated by the frozen engine.

The replace step runs on a **JVM 11+**, because Rhino 1.8.0 is class-file 55 and
the operator's Java 8 is not: `run_golden.sh` takes `REPLACE_JAVA`, else finds
the Android Studio JBR, else a `java` on `PATH` that reports 11+, and records
which one it used. The content step (`golden.json`) keeps its own Java 8 run and
its own toolchain record; only the compile unit is shared.

Reproduce both steps:

```
bash tool/html_content_oracle/run_golden.sh
```

## What the replace corpus decides

- The **trim comes first**: the replacement sees the trimmed joined text, so a
  pattern that matches the formatter's `U+3000` indent cannot fire
  (`trim-precedes-the-replacement`), and a marker alone on a line leaves a
  line that the stage then indents, `　　` and all (`marker-alone-on-a-line` —
  the row #101's product test pinned the other way, corrected against this
  golden).
- The frozen's `replaceRegex` is a **Java** pattern: `\s` is ASCII-only, so
  `\s+` never matches an ideographic space inside a line
  (`intra-line-ideographic-space`).
- The three-part `##…##$1` form **cannot fire in this stage**: after the trim no
  line starts with whitespace, so `\n\s{2}` has nothing to match
  (`replacement-dollar-group-cannot-fire`); a `$1` with no group falls back to
  the frozen's literal `String.replace` (`replacement-dollar-without-a-group`),
  and the fourth field answers the replaced *match* only
  (`replacement-first-field`).
- The templates are the frozen `evalJS` bindings: `title` (the chapter title),
  `book.author`, `chapter.title`, and `result` (the trimmed joined text), each
  substituted into the rule text *before* the `##` split; a `try` as the whole
  program answers its completion value, and its catch answers the fallback
  (`template-*`, `template-undefined-name-catch`,
  `template-result-is-the-joined-text`).
- A `##` field on the content rule and a non-empty replacement are **two
  independent fields**: the content field's replacement runs on the page read,
  ahead of the formatter, and the stage's on the joined text
  (`content-rule-owns-a-replacement`, `content-rule-removal-and-stage-group`).

## What the replace corpus does not cover

- The device golden: the frozen APK's own `BookContent.analyzeContent`
  (`not-run`, owned by #106).
- The selector read itself: `pageValues` is a declared input, so the jsoup
  extraction is the product's Rust adapter's surface (`tool/html_oracle/`).
- The stage read's `unescape = true` (`AnalyzeRule.kt:289-296`) is a recorded
  divergence: the frozen decodes an entity the replacement introduced through
  Apache Commons' HTML4 table, while the product's replacement runs in Dart over
  the adapter's value and leaves the entity text. The golden holds the frozen
  answer, and `test/content_replace_differential_test.dart` asserts both — the
  read-level entity pass is #104.
