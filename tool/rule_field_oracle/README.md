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
