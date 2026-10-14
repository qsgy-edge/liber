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


## Read context, caller completion and original item selection

`ReadContextOracle.kt` executes 37 repeated observations over the preserved
actual compiled getters. Its 36 product-comparable rows include 34 value rows
and two error/state controls; one detached-node negative is frozen-only.
`BookVisibilityOracle.kt` adds eight observations with the preserved mutable
Book name/author entity and source-verified conditional merge points.
`BookAliasOracle.kt` adds two actual AnalyzeRule.get/BaseSource.get observations
with and without a Book. No new entity stub, constant getter answer or Java
container/type provenance protocol supplies these values. Caller order and
merge sequences are transcribed from the pinned callers; the harnesses do not
execute whole BookList/BookInfo/TOC classes or a device.

```sh
python tool/rule_field_oracle/run_read_context.py --compiled <preserved-oracle-v8-dir> --output <external-scratch>
python tool/rule_field_oracle/run_book_visibility.py --compiled <preserved-oracle-v8-dir> --output <external-scratch>
python tool/rule_field_oracle/run_book_alias.py --compiled <preserved-oracle-v8-dir> --output <external-scratch>
```

Implicit nested scalar reads retain the original analysis content. Explicit
read targets and intermediate JS result remain separate; nested getString
completes its own replacement/scripts/HTML4 tail on the same evaluator/scope.
Detail getters complete name, author, kind, wordCount, lastChapter, intro,
cover and toc in order; TOC getters complete per item. Observed name/author
merges become visible immediately. Single-argument java.get(bookName) reads the
current Book name when that scope exists; source.get, ordinary state and the
HTTP overload retain their paths, with no-Book fallback tested separately.

HTML items retain the original document plus ordered selection/focus steps.
The optional parentIndex addresses the completed parent selection's final
merge/reorder vector, and None retains the existing all-context behavior.
Relative selection, array indexing, src/result and returned node serialization
use that path without a detached outerHTML reparse or rewritten index syntax.
The field is officially generated through FRB 2.12.0. Its automatic content hash
stayed unchanged, so matching native source/generated hashes and the actual DLL
identity are required; the hash constant alone cannot distinguish the old DLL.
Static search without kind uses one batch; nonempty static kind uses a second
batch of explicitly grouped per-item TextList jobs. Dynamic reads have no fixed
batch-count claim. Item content serialization is lazy, and kind keeps list/raw
semantics without a scalar tail.

The cancelled frozen observation cancels a Job before its getter begins.
The product control cancels at the existing toast callback and asserts that it
was reached. Ordinary log does not invoke that callback. Their timing differs:
error/state and saved-value assertions are controls, not scalar-value or
same-trigger-time parity. The current read-context suite is 39 tests: 34 value
comparisons, two error/state controls, one identity and two retention controls.
Book visibility/alias has ten value rows and two identity controls.

Controller branch verification after the matching native build records Rust
34/34 (including the six parentIndex cases), Dart MCP 324/324, the existing HTML
Android-golden comparisons 45/45, host checks 106/106 and bounded MCP analysis
No errors. The Dart total includes identity/error/policy/type guards and is not
324 frozen parity rows. Frozen outputs/producers/manifests remain unmodified;
final layout/comment changes are bound by exact analyzer-token and string
lexeme equivalence. Detailed raw receipts and source/DLL bindings live under
`C:/Users/17945/AppData/Local/liber-evidence/batch26/93/review-round3/`.
Fresh independent review, integrated verification, Windows scratch driven run
and other-platform affected rows remain subsequent gates. Prior Java/type,
nested-put policy, direct Elements/explicit object and coverage residuals remain
explicit; this branch result does not release downstream tickets.


## Caller edges: conditional TOC, host lists and detail fallback

`CallerEdgesOracle.kt` adds 24 repeated auxiliary observations using the same
preserved, hash-checked actual getters/classes/JARs. Six rows transcribe the
pinned BookChapterList order and its nonempty-title condition; nine exercise
String JSON host getStringList through an encoded inner rule and outer scalar;
nine establish Book-before-getter/init and completed toc behavior. Two of these
24 rows record real toc errors, so this is not 24 scalar parity passes.

```sh
python tool/rule_field_oracle/run_caller_edges.py --compiled <preserved-oracle-v8-dir> --output <external-scratch>
```

The transcript completes name, URL, tag and volume for every TOC item, then
VIP/pay only for nonempty titles. JSON URL state is visible to the following
getters; skipped items retain the first four getter effects without executing
VIP/pay. The existing native/static batches and chapter address policies remain.
JSON host list reads reuse the ordinary resolved-list steps already used by
kind: no second resolve, replacement per item, literal/list application, and no
scalar entity tail. The current evaluator/src and named script-list refusal are
preserved; kind's known NativeObject branch remains separate and unchanged.

Both detail-read entries bind the incoming Book before the first getter; JSON
also does this before its existing init. Search fallback completes toc once but
does not fetch it. Normal details consumes that already-read address rather
than reading it twice. No HTML init capability or public model/store interface
is added. BookInfo's kind/cover updates are nonempty-only; empty reads retain the
hit values and nonempty cover keeps the existing URL resolver.

N5 kind/cover tests are explicitly source-derived retention controls based on
BookInfo.kt:85-88 and135-138. The preserved Book stub lacks those fields: it is
not expanded and no N5 actual-entity golden or whole BookInfo execution is
claimed. The focused suite has34 tests:24 auxiliary rows (including2errors),
one evidence identity,one named policy guard and8 source-retention controls.
Its initial real MCP result was8pass/26fail; the separate combined kind/cover
red selected8 with2pass/6fail, then the complete suite passed34/34.

Controller affected MCP groups passed153+100+51=304 with9 normal teardowns,
so this repair records338 product checks including controls, not338 frozen
parity rows. Existing HTML45 and host106 gates passed and precise three-file
analysis returned No errors. The original9-suite and analysis timeouts remain
no-result. Layout-only source changes are linked by exact analyzer tokens and
string lexemes; actual requests, sources and results are retained in external
review-round4 evidence. Frozen producers/corpora/output copies are unchanged
after that execution. Native/generated bytes and matchingc619560d DLL remain
unchanged, with earlier Rust34 evidence reused rather than rerun. All prior
Java/type/policy/cancellation/coverage/platform residuals remain explicit.

## Next TOC getter and detail metadata visibility

`NextBookStateOracle.kt` adds 12 repeated actual auxiliary observations using
unchanged preserved classes/JARs and the original Book stub. It transcribes
BookChapterList's list acquisition, completed next getter, then item reads.
Six nonempty value rows cover script-only, extraction-plus-script and resolved
literal-plus-script fields; four rows record real next errors and saved state;
two zero-item rows support the existing empty-TOC policy controls. This is not
whole BookChapterList execution or 12 scalar parity rows.

```sh
python tool/rule_field_oracle/run_next_book_state.py --compiled <preserved-oracle-v8-dir> --output <external-scratch>
```

HTML only prepares pure static next work in its existing batch. After list
acquisition, both pipelines complete next once before item getters and before
the empty-list policy, then return the saved list to the existing page walk.
Declared pages skip next resolution/application. Resolved literal list reads
use existing RuleField list application and sourceScriptTexts; their sibling
script's empty array does not become an address `/[]`. Ordinary extraction,
per-item scripts, container provenance and multi-match threading are unchanged.
The shared nextContentUrl caller has affected product regression coverage;
this bounded result does not establish all next-list shapes or platform parity.

Each supported detail metadata getter now publishes its completed nonempty
merge to the existing local Book snapshot before the next getter. Word count
and intro keep their existing formatting boundary, cover its existing resolver;
empty values retain the prior snapshot. Conditional name/author updates,
original URL/rawAddress, request options and one final toc read remain. No
public model or persistence interface is added. Eight F2 controls are explicitly
source-derived from pinned BookInfo/BaseBook/Book conditions, including later
visibility, empty/no-match retention and conditional rename; the Book stub is
not expanded and there is no F2 entity golden or whole BookInfo execution.

The new focused suite contains23 tests:12 auxiliary-linked value/error/zero
rows,8 source-derived F2 controls,2 declared-page URL/options controls and1
identity control. The final valid pre-fix MCP run selected23 with9pass/14fail
(10 F1 and4 F2 behavior failures), then passed23/23. Initial helper compilation
selected0 behavior rows; a later12-row test-map setup failure and the corrected
raw-address versus normalized-URL assertion remain separate evidence. Nine
existing N4 rows now assert complete request URLs/methods and Book URLs with
unchanged inputs, rules and value goldens.

Controller affected checks passed153+100+85 plus17 HTML next-content caller
checks:23+153+100+85+17=378, with12 normal teardowns. HTML45 and host106 gates
passed; exact four-file MCP analysis returned No errors after one preserved
no-result timeout.378 includes errors, identity, policy and source controls,
not378 frozen parity rows. Final layout-only edits retain exact analyzer tokens
and string lexemes for all four changed Dart files. Raw requests/results and
source/DLL pins remain in external review-round5 evidence. Earlier338/45/106
and Rust34 retain their original scopes; unchanged packages and matchingc619
DLL permit native reuse without a new build or Rust execution. Official finish
steering failed twice with EPERM; the controller interrupted/paused the writer
and resumed the same session for final delivery. This was a delivery failure,
not a code/test failure. Fresh independent review, integrated verification,
Windows scratch driven UI, other affected platforms and downstream release
remain controller gates; all earlier type/policy/cancellation/coverage residuals
remain unaccepted.

## Current TOC chapter/title binding

`TocChapterBindingOracle.kt` adds16 repeated actual auxiliary item observations
against unchanged preserved classes/JARs. Each item binds an original Chapter,
completes name, then URL/tag/volume and conditional VIP/pay. The original stub
has title/url/index and is unchanged; tag/flags entity state and whole caller
execution are not claimed. Ten rows cover title/URL/snapshot/live alias/options,
two empty/skipped item controls, two errors/state and two plain controls.

```sh
python tool/rule_field_oracle/run_toc_chapter_binding.py --compiled <preserved-oracle-v8-dir> --output <external-scratch>
```

Actualv1 compile0/run1 failed its strict JS comparison against wrapped JVM
String properties. One explicitly approvedv2 changed only10 fixture predicate
and snapshot/trace fields to explicit String text observations; harness/runner
and original stub remained unchanged. Actualv2 compile0/run0 produced16
repeated observations. Originalv1 inputs/classes/logs remain unpromoted.
An upstream HTTP/2 stream failure then interrupted preparation; the same writer
resumed with all recovery pins unchanged and reused successfulv2 output.

Both pipelines now establish an empty current Chapter/title at each item turn,
publish the completed name before URL/tag, and expose the exact completed raw
address to later TOC getters. One private nullable address override separates
this temporary scope from normal supplied-content snapshots, including an
empty Uri. Item/page finally blocks clear temporary state on completion, skip
and error; page list/next runs without a previous Chapter. Existing final URL,
volume/options/flags/dedup construction and F1 next completion remain.
No Chapter tag/flags member or public model/runtime protocol is added.

The existing one-argument java.get(title) returns current chapter.title only
when a Chapter exists; ordinary source.get, other keys, no-Chapter fallback and
two-argument HTTP get remain. RuleField's title alias likewise uses its existing
source-variable fallthrough without a Chapter. Scalar preflight recognizes an
actual top-level get token in the first rule part as a literal value, matching
existing RuleField/frozen behavior; list extraction, put-only, malformed/bare
paths and replacement-only tokens retain their earlier boundaries.

The focused suite is31 checks:16 auxiliary-linked rows,8 explicit source-derived
page/repeat/content/empty-Uri controls,6 scalar preflight boundaries and1identity.
Post-binding25 selected20pass/5fail:two independent live Java aliases,one scalar
JSON preflight refusal andtwo new fixture transport-expectation corrections.
The preflight before-run selected6 with5pass/1fail, then full31/31 passed.
Original errors, setup failures and a complete reporter behind an MCP timeout
remain distinct; no timeout is counted as a returned API pass.

A necessary backup-variable regression exposed an older fixture mismatch:
JSON.parse supplied the already supported NativeObject, while its getters used
JSONPath $.title/$.toc. Actual imported-column/direct Book.getVariable/JS parse
assertions passed before the same EmptyTOC. Only fixture getters were corrected
to direct title/toc keys, retaining backup data/init/title expectation and adding
chapter/raw/normalized URL plus three actual legacy stage/path assertions.
The target and final7-variable suite passed. This was not G1 storage damage;
this legacy fixture does not observe HTTP methods. Existing executed NativeObject
key/toc cases were reused without a new entity golden or JVM run.

Controller evidence contains460 unique successful product checks:31+153+100+85
+36 unchanged non-Book rows from the originald group+48+final Book-variable7.
The originald42pass/1fail and attribution failures remain unchanged; duplicate
probes are excluded. Fifteen completed teardowns include that original failed
group. HTML45/45 and host106/106 passed; the old host snapshot expectation
failed105/106 and was corrected to check live title and stored source separately.
Final exact nine-file MCP analysis returned No errors after preserved timeout
and concrete lint diagnostics. Single-statement blocks and removal of one unused
private test helper are connected by an AST-selected structural proof, then
strict final token/string equivalence; new lint fixes remain in the candidate.
These checks include source/policy/error/identity controls and are not460 parity
rows. Old378/45/106 and unchanged Rust34 including6/c619 DLL retain their actual
historical scopes. Fresh review, integration, scratch driven UI, other platforms
and downstream release remain controller gates; prior residuals remain explicit.
