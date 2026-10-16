# HTML getElements retained host evidence (#105)

These files retain the actual successful v2 host-JVM execution for repeatable
product comparisons. Inputs, output and receipts preserve their original bytes;
product results do not define or rewrite the golden.

- `legal-string-v2-fixtures.json`: synthetic input and the 12 actual scripts.
- `legal-string-v2-golden.json`: actual frozen host-JVM results, never generated
  from product output. SHA-256:
  `7725111c0626d7a9702e45c24a96ccf959ad1ccead582a21e2f0f926ab70db70`.
- `legal-string-v2-manifest.json`: original successful receipt, including source,
  stub, toolchain, class-tree, input, output, prior-failure and null-mismatch pins.
- `legal-string-v2-run.log`: original stdout (`executed 12 frozen HTML getElements rows`).
- `GetElementsOracle.kt` and `manifest.json`: original harness and its original
  compile/run receipt (compile exit 0; original pre-v2 run exit 1). The successful
  v2 receipt references that original manifest; it does not turn its failure into
  a success. The harness hash is in the original manifest.
- `pins.json`: SHA-256 of each copied file. The Dart evidence control verifies
  them, corpus identity, ordered row IDs, successful v2 exit and the device gap.

Authority: Git object `14dd24945b2914ce2708b8abaa4ee67ceef892af` in the named
Legado repository. The existing Kotlin 2.2.20/JBR 21 host run executed the real
AnalyzeRule/AnalyzeByJSoup/RuleAnalyzer and frozen Rhino module with jsoup 1.16.2;
unused Android/entity/network branches use pinned fail-closed compile stubs.
Bounded helper transcriptions and host-JVM execution do not establish Android,
whole-entity, source-network, or platform parity. Full sources, jars, compiled
classes, runners, logs and earlier failures remain in the external evidence
folder; this directory adds no runner or engine.

The original null invocation threw Rhino WrappedException caused by Kotlin's
non-null-parameter NPE; the product's existing null/omitted early `[]` guard is
preserved as an explicit mismatch, never a matched row. The first legal subset
failed on nonexistent frozen `Elements.selectFirst`, and the original wrapper
then failed to print that diagnostic through Windows GBK. Both failures remain
external with their original pins. V2 removed the null sub-call and used
`es.select('b')[0].text()` for the collection case, retaining all 12 row IDs.
The existing product's collection selectFirst convenience is not an oracle claim.

`test/html_get_elements_test.dart` runs the actual HtmlSourcePipeline at the
book-info author field or, for the two node-context rows, at a per-item search
author field after the same selectFirst context binding as the harness. JSON
outputs are decoded and compared directly with the retained golden values.
Separate controls describe product guards, refusal boundaries, collection
usability and original-document identity; they are not new frozen observations.
The earlier `955f33c` candidate passed 47 element and 11 adapter cases within
629 distinct Dart cases, with 25 successful teardowns and six-file analysis
without errors. Its later array-identity and lexical-token repair adds 12 real
pipeline/runtime controls: the controller observed six target failures before
the fix, then reran all 641 cases successfully with 27 normal teardowns. The new
controls cover ordinary JavaScript extensions, not new frozen Java observations.
All 17 runtime gates, including 106 host checks, and three-file analysis passed
on the repaired source. Prior native 38/643 results retain their earlier scope;
142 package pins and the matching DLL stayed unchanged, without a rebuild.
Final layout-only edits preserve verified token and string-literal lexemes,
excluding comments and optional trailing commas.

The CI HTML row checks 45 fixture expectations and records frozen comparison as
not-run. This repair round also compares those already executed observations
offline with the retained Android device golden: 45/45 match, without an extra
product invocation or device execution. The earlier separate comparison remains
historical evidence. Neither establishes whole-feature/platform parity.
Independent review, integration, a new Windows app/scratch driven run and the
remaining platform acceptance are pending.
