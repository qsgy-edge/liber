# Rule-field value classification oracle (#93)

Frozen authority: Legado Git object `14dd24945b2914ce2708b8abaa4ee67ceef892af`.
`run.py` materializes object bytes into external scratch and executes the actual
`AnalyzeRule` and Rhino classes. The source and classpath hashes in the generated
manifest bind this host-JVM observation. This is not an Android/device run.

```sh
python tool/rule_field_oracle/run.py --output <external-scratch> --jars <pinned-jar-dir>
flutter test --no-pub test/rule_field_test.dart --plain-name 'frozen literal value reads' --reporter expanded
```

The jars directory must contain the exact three artifacts pinned by
`tool/html_content_oracle/jars.sha256`; the remaining compiler/classpath jars are
looked up only in the named Gradle module directories and their actual hashes are
recorded in the manifest. No download or native rebuild is performed. The full
compile/run logs stay in external scratch. `evidence/jvm-host/golden.json` is an
unmodified copy of the executed output, and its manifest records that execution's
source, corpus, harness, runner and dependency hashes. It is a branch-scoped test
input until independently reviewed and integrated.

The final corpus has 11 cases, each executed twice for determinism against HTML,
XML-shaped text and JSON content: 33 rows. Nine cases per format return values;
two per format deliberately reach extraction without a declared answer and fail
with the requested extraction rule. The compile-only JSoup/XPath/JSONPath stubs
never supply an answer. The rows prove the deciding classification and text/JS
composition; they do not prove extraction parity or a product XML engine.
The product regression passes XML-shaped markup through its existing HTML caller.

Deciding frozen lines (all from the object above):

- `AnalyzeRule.kt:524-550`: mode markers and JSON-content routing before
  interpolation. `:559-572` removes puts and switches to `Mode.Regex` if the
  first interpolation precedes replacement fields. This applies to mixed text,
  not only a sole expression. `:638-695` substitutes and then splits `##` fields.
- `AnalyzeRule.kt:288-303`: `getString` returns the substituted rule for that
  mode, applies replacement, then runs a sibling JS segment. A selector-looking
  answer stays literal. HTML/XML and JSON agree on these value rows; an
  expression confined to replacement preserves Default or Json routing.
- `AnalyzeRule.kt:166-239` and `:328-389`: string-list and element reads are
  different boundaries. The patch changes scalar value callers and leaves the
  existing array/list and DOM extraction wiring in place.
- `RuleAnalyzer.kt:340-364`: `innerRule` preserves surrounding text when it
  substitutes an embedded rule. This generic splitter does not decide the
  `SourceRule` mode; it is recorded for source navigation, not substituted for
  executing `AnalyzeRule`.

The product tests load the sole versioned golden path and check corpus, golden,
harness, runner hashes and the baseline before comparing actual search, detail
and chapter value callers. A selector with an expression only in its replacement
also runs through the native product adapter to guard against broad
reclassification. Logs and additional native/source binding receipts are retained
under `C:/Users/17945/AppData/Local/liber-evidence/batch26/93/`.

## Review-repair corpus and shared serialization checkpoint

`review-fixtures.json` and `ReviewOracle.kt` execute the actual pinned
AnalyzeRule/JSoup/JSONPath/Rhino classes at String, selected node/collection,
JSONPath Java-container and script-created NativeObject boundaries. The final
review corpus has 85 fixtures, 252 full-table HTML4 checks and one separately
retained repeat of the nondeterministic NativeArray scalar: 338 observations.
This is not 338 extraction/parity passes. Real exceptions and the two actual
JVM-identity strings remain in the golden. Kind records both the actual list and
the executed Kotlin join, including null and order. The original 33-row
classification corpus remains preserved separately.

```sh
python tool/rule_field_oracle/run_review.py --inputs <verified-105-input-dir> --jars <own-pinned-jars> --output <external-scratch> --export-dart lib/source/html4_entities.dart
python tool/rule_field_oracle/export_serialization.py
flutter test --no-pub test/rule_field_review_test.dart --reporter expanded --concurrency=1
```

The runner verifies the immutable Git-object sources against #105's preparation,
checks every actual classpath hash, verifies reached helper transcriptions and
uses one heap-bounded JVM at a time. Compilation/run receipts stay external;
`evidence/review-host` contains copied executed output and minimal provenance.
`html4_entities.dart` is automatically exported from the fixed commons-text
1.13.0 public lookup data, never hand-edited. UTF-16 code-unit comparisons retain
surrogates rather than allowing JSON/UTF-8 replacement to hide differences.
The Dart helper preserves overflow references and propagates illegal-code-point
failure; it performs a single, case-sensitive, semicolon-required decode.

The controller's original 13-case probe is preserved in external evidence and
integrated into `test/rule_field_review_test.dart` with executed expectations.
The scalar corpus now targets author fields, while kind uses the actual
string-list/join boundary. Known Java-container JS coercion and NativeArray
scalar format differences are explicit guards, not successful compatibility
rows. `LIBER_REQUIRE_RULE_FIELD_PARITY=1` enables strict comparison of those
known gaps; the original strict 0-pass/4-fail receipt is retained. The two node
entity rows became exact comparisons after the controller-approved shared
node/collection toString repair; other DOM getters and Root Document behavior
are outside that repair.

The raw script/style checks exposed a native pretty-printing discrepancy.
The fixed JAR's actual bytecode and reflection prove that the opening condition
uses Tag.isBlock, while the closing condition uses Tag.formatAsBlock. Only the
first predicate in `serialize.rs::should_indent` changes. The generated Rust
fixture file comes from the real raw serialization golden and uses LF-pinned
bytes. No tag-table, native API/ABI, generated binding or dependency changes are
part of this patch. A matching DLL rebuild and affected serializer/adapter
checks must bind the native source checkpoint before this result can be claimed;
old-DLL passes cannot validate the new Rust condition.

## Post-native script-only scalar tail

`scalar-tail-fixtures.json` and `ScalarTailOracle.kt` add 12 executed, repeated
observations without rebuilding or rerunning the original frozen corpus. The
runner verifies the existing review-host receipt, source Git objects, compiled
inputs and classpath hashes, records the actual compiled class hashes, and
compiles only the small new harness with a 256 MB heap into external scratch.
`evidence/scalar-tail-host` preserves that run's unmodified golden and receipt;
the original classification and review goldens remain unchanged.

```sh
python tool/rule_field_oracle/run_scalar_tail.py --compiled <existing-oracle-v8-dir> --output <external-scratch>
flutter test --no-pub test/rule_field_scalar_tail_test.dart --reporter expanded --concurrency=1
```

Eleven rows compare reachable product callers: search item Element content,
literal plus sibling script/count, and String page content whose script creates
real Jsoup nodes or Elements. Ordinary scalar reads perform one HTML4 tail after
scripts; kind uses the actual list/join boundary with no tail; chapter content
keeps `unescape=false`. The content scripts remove tags and join lines before
the caller so their entity-bearing values survive the existing formatter. Those
rows isolate the disabled tail, not #104's entire chapter formatting order.
One direct `setContent(Elements)` row is frozen-only: the product does not expose
that init-content boundary, and it is not counted as parity. The focused product
suite has 11 differential rows plus one provenance check, with no mismatch guards.
The deciding frozen tail is `AnalyzeRule.kt:308-314`; list reads use `:166-239`.
No new DOM getter, native ABI or explicit object/prototype input protocol is added.

## Five-finding review repair and scripted extraction tail

`block-five-fixtures.json` and `BlockFiveOracle.kt` execute 37 repeated frozen
observations using the preserved compiled AnalyzeRule/Jsoup/Rhino/JSONPath
classes. Sequence rows invoke real getters in the pinned BookList field order;
they do not execute the entire BookList class. The corpus distinguishes reverse
parameter evaluation from source-order text assembly, per-item field order,
JSON URL position, empty versus nonempty replacement, complete nested scalar
reads, and single original mode-head normalization for known NativeObject.

```sh
python tool/rule_field_oracle/run_block_five.py --compiled <preserved-oracle-v8-dir> --output <external-scratch>
python tool/rule_field_oracle/run_intro_tail.py --compiled <preserved-oracle-v8-dir> --output <external-scratch>
```

The second runner executes 18 repeated typed getter observations and the actual
compiled frozen `HtmlFormatter.format`. It compiles exact Git-object formatter
bytes, verifies the older content-oracle pin's sole CRLF difference, and records
both identities. String, selected node and decoded Java map inputs are distinct.
Scalar script inputs keep raw matched text; ordinary scalar matches join with a
newline before replacement, URL scalar reads take the first, and replacement
runs once on that scalar. No-match ordinary scalar reads skip the main script
after its substitution; URL reads retain an empty String for a script to supply
an address. Identity/double-entity, raw-before-script, multi-match/newline,
replacement/replaceFirst, no-match/empty, list and disabled-tail rows protect
those boundaries. TOC names and ordinary content titles exercise the same
scalar read; the content body retains `unescape=false` and its existing order.
The intro formatter remains unchanged. These are actual getter and formatter
executions, not entire BookList/BookInfo/BookContent or device runs.

The product reuses existing TextList jobs only for nonempty scalar extraction
with scripts and `unescape=true`; pure static fields retain native Text jobs.
The private document job record holds the existing finished/raw job alternatives
inside the same stage batch. Item reads retain their actual node context. No
native source, output kind, adapter interface, parser or engine is added.
The existing RuleFieldContext extraction callback now returns a completed nested
getString, on the same runtime/state and with one tail, before `@put` stores it.
Known NativeObject bare keys defer validation only for script-only book-info init
and the eight existing getters; other inputs and ignored fields keep their named
refusals. Ordinary decoded maps are not reclassified as NativeObject.

The focused block suite has 44 tests: 34 value comparisons, one actual nested
error propagation control, one identity check, five input/preflight guards, one
preserved nested-put rejection guard, and two tool getter comparisons. Its 37
frozen observations include NativeObject `unescape=false` (frozen-only) and a
nested put that frozen actually permits. The product's existing nested-put ban
is preserved by explicit controller direction; that rejection is a recorded
policy difference, not parity or a compatibility acceptance. The intro suite has
21 tests: 18 caller comparisons, one identity check, one formatter check over all
18 actual outputs and one comparison of the same tool scalar getter.

`evidence/block-five-host` and `evidence/intro-tail-host` are unmodified copies of
the respective final executed outputs and receipts. Every previous corpus,
golden and receipt is retained. The old intro test now reads the executed typed
formatter output rather than its earlier source-derived expected string.
Java container/NativeArray differences, direct Elements init, broad type/DOM
contracts and #104's chapter-wide ordering remain separate gaps. Blank selector
plus nonempty replacement followed by scripts is outside this new raw-extraction
branch; the bounded corpus does not establish all such rule shapes.
