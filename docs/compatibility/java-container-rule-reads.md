# Java containers in rule reads (#128)

Status: recorded determination on batch 27's branch, based on the frozen revision
`14dd24945b2914ce2708b8abaa4ee67ceef892af`. No container carrier or runtime change
is introduced. Under the controller's used-source threshold, no resolved used
call site observes the Java forms below. Observation reachability beyond the
counted predicates remains unmeasured; this is not a claim that synthetic rules
cannot observe the differences.

## Frozen determination

Paths below are relative to the frozen Legado checkout. `AR` means
`app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt`; `JP` means
`AnalyzeByJSonPath.kt` in the same directory; `RE`, `RW`, `CS` and `SB` mean,
respectively, `modules/rhino/src/main/java/com/script/rhino/RhinoScriptEngine.kt`,
`RhinoWrapFactory.kt`, `RhinoClassShutter.kt`, and
`modules/rhino/src/main/java/com/script/ScriptBindings.kt`.

The ticket's shorthand combines two different origins. A script-created
`NativeObject` is a Rhino script object, **not** a `LinkedHashMap`. A JSONPath
object is a Java `LinkedHashMap`; a JSONPath array is a Java list. Returning a
script object/array through a Java rule method does not give it the Java map/list
surface. `RE:309-320` unwraps Java wrappers and concatenated strings only;
`SB:24-30` binds values with `Context.javaToJS`.

| Observation | Exposed to a rule by the frozen? | Frozen deciding path and executed result | Resolved used sources | Shared diagnostic pools: tail/failure / string input |
|---|---|---|---:|---:|
| Script object Java class identity (`NativeObject`) | Its JS identity is observable; Java class reflection is unavailable. | `AR:328-357`, `RE:309-320`, `CS:50,114,123-134`, `RW:48-57`: `Array.isArray` false, `instanceof Object` true, `typeof getClass` undefined; `instanceof Packages.org.mozilla.javascript.NativeObject` false. | 0 | 104 / 54 (unassigned) |
| JSONPath object Java identity (`LinkedHashMap`) | Yes, via Java type tests and the wrapper tag. Class reflection itself returns null. | `JP:15-20,125-137`, `AR:346-349`, `RE:330-342`, `CS:123-134`, `RW:48-57`: `instanceof Packages.java.util.Map` and `LinkedHashMap` true; `[object JavaMap]`; `getClass()` null. | 0 | 104 / 54 (unassigned) |
| Script array Java identity (`NativeArray`) | JS array identity yes; the Java class test is hidden. | `AR:328-357,363-389`, `RE:307-320`, `CS:114,123-134`: `Array.isArray` and `instanceof Array` true; `typeof getClass` undefined; protected NativeArray Java type test false. | 0 | 104 / 54 (unassigned) |
| Container member `size`, including Java-typed access | Yes for JSONPath Java map/list: `size()` gives 2/3 in the synthetic cases; `get` exists. Native script object/array has no such members. | `JP:125-137`, `AR:346-349,379-387`, `RE:330-342`: Java wrapper members survive. Bare `size` is a function, not its integer result. The script values give `typeof size` undefined. | 0 | 104 / 54 (unassigned) |
| NativeObject string form | Yes: direct JS `String` and `toString` give `[object Object]`. A JSONPath map instead gives `{a=x, b=1}`. | `AR:269-281,308-314,328-357`, `RE:309-320`: the NativeObject branch and final JVM `toString` are different from a JSONPath map's conversion. | 0 | 109 / 54 (unassigned) |
| NativeArray string form, including identity suffix | Yes indirectly through scalar rule conversion. Direct JS `String`/`toString` gives `a,,b`; `java.getString('@js:["a",null,"b"]')` gives `org.mozilla.javascript.NativeArray@` plus a JVM identity suffix. JSONPath array JS String gives JSON text instead. | `AR:288-314,328-357`, `JP:125-137`, `RE:307-320`: `evalJS` returns a JVM NativeArray, and `getString` invokes JVM `result.toString()`. The measured class prefix is in the raw observation, not inferred from an error name. | 0 | 109 / 54 (unassigned) |

The last column repeats **shared diagnostic pools**, not resolved receivers or
conservative per-observation reachability counts. The complete traversal finds
**228 script-bearing fields** in the five rule groups. The original
`parseRuleField`-accepted subset remains **225 fields**, with **101** selected
by its tail-warning predicate across **51** source records, including **20**
ECMAScript parser failures. That predicate selects a parser failure or a last
script-tail label containing `unknown`, `loop-completion` or `undefined`; it is
a classification of the last script body, not an analysis of the whole field.

Three used fields were previously dropped by the rule parser's multiple-
extraction-segment refusal at `lib/source/rule_field.dart:236`: position **2**
`ruleExplore.kind`, **266** `ruleContent.content`, and **1645**
`ruleSearch.author`. The corrected instrument records every rule-parser failure
without its private error text. All three script-bearing failures are retained
regardless of their raw tail labels; position 266's raw last body is labelled
`unknown-call`. This conservative retention of parser failures gives **104**
tail-warning-or-rule-failure fields across **53** records among **228** fields.
It does not make that count a conservative reachability bound.

The two string-form rows also retain **5** fields containing **8** literal
JSONPath `java.getString` calls whose response value types are unknown. They do
not overlap the tail-warning pool: the historical accepted-subset union is
**106 = 101 + 5**, and the complete failure-retaining union is
**109 = 104 + 5**. Both are diagnostic populations, not complete observation
residuals.

A separate scan finds **54 fields across 44 records** whose last script has the
heuristic label `string` but which contain a string-result call with a receiver
or argument labelled unresolved by the same classifier. The scan visits **every
script segment**, including all six fields with multiple script bodies, and
counts each field once. It checks `String` and the classifier's string-returning
method spellings, including `get`, `toString`, `join`, `stringify` and `replace`;
method spelling does not resolve the actual callee, receiver or conversion input.
A flag can include a standard host/global call that this heuristic does not
resolve. Position **326** `ruleContent.content` is included because its `String`
argument is an unresolved call, despite its final `string` label. Synthetic
controls retain `String(unknownHelper())`, an unresolved `toString` receiver, an
unresolved `get` receiver and an unresolved input in an earlier segment; a
literal `String(1)` control is unflagged.

These **54** fields are separate from the 104 tail/failure fields. One overlaps
the five response-dependent JSONPath fields (position **330**
`ruleSearch.kind`), so **53** are additional to the 109-field string-row pool.
The 54-field input pool is repeated as **unassigned** for every observation row:
the instrument cannot attribute an unresolved helper/input to an identity,
member or string observation. It establishes neither 54 observers nor complete
coverage of possible observations. No conservative per-observation reachability
residual is claimed. A receiver/input analysis, including aliases, computed
members, shared helpers, earlier side effects and runtime-selected values, would
be needed before such a bound could be claimed; this correction does not add
that analysis or execute source scripts.

## Used-source measurement

The approved input is the 2026-09-17 backup, SHA256
`e46452c9b824d41c1333bb58965a7709041c0b46b3fa2ff11372d7b3e4c1abb8`:
**150** resolved used source records out of **8787** exported records. Positions
below are zero-based positions in `bookSource.json`. No source names, addresses
or rule text are published.

| Token / call population | Used records | Collection records | Resolution |
|---|---:|---:|---|
| `java.getElement` in all string fields | 0 | 67 | No used producer of the JSONPath Java object/list host result. |
| `java.getElements` in all string fields | 1 | 133 | Position 375, `ruleToc.chapterList`: one literal HTML selector; ordinary node attribute/text extraction. |
| `java.getString` in all string fields | 14 | 514 | 22 call sites in 18 fields: 13 literal HTML/key rules, 8 literal JSONPath rules, 1 dynamic rule argument; all have one argument. No literal script rule or explicit container-content overload. |
| `java.getStringList` in all string fields | 0 | 55 | No used call site. |
| `.getClass(...)` | 0 | 0 | No explicit class-reflection observer. |
| NativeObject / NativeArray / LinkedHashMap / JavaMap / JavaList name | 0 | 0 | No explicit class-name observer. |
| Java map/list `instanceof` spelling counted by the probe | 0 | 0 | No explicit Java type observer under this token predicate. |
| `.size` (including comments and strings) | 1 | 87 | Position 4651, `ruleExplore.bookList`: the only used occurrence is in a **comment**, so there are zero code receivers to classify as Java. |

The 14 `getString` records are positions 4, 17, 83, 121, 125, 144, 151, 162,
321, 326, 330, 375, 878 and 1169. Position 17's `ruleBookInfo.init` contains
the single dynamic rule argument; it stays unresolved. The five JSONPath fields
with response-dependent string forms are position 321's `ruleBookInfo.kind`,
`ruleExplore.kind`, `ruleSearch.kind`, position 326's `ruleToc.updateTime`, and
position 330's `ruleSearch.kind`. The counts describe
call argument shapes, not whether an extraction's response happens to contain
a map or list. In particular, no zero count here proves arbitrary computed
code or a shared-library function cannot create an observer.

The #98 measurement uses the same backup hash but a narrower population:
`java.getElements` in class-A **HTML element-list scripts**, 1 used / 65
collection records (67 collection call sites). The 1/133 count above scans all
string fields and includes non-class-A occurrences. The unchanged #98 report
was also rerun and retained, so those populations are independently comparable.

## Decision and retained differences

The controller authorized static call sites with resolved Java receivers as the
instrument, required unresolved fields to remain counted, and directed that an
observation with zero resolved used sources receive a recorded decision rather
than an implementation. On that basis the product deliberately retains its
plain JS values for these unproven Java-container dependencies. No operator
source is **shown** to depend on the Java forms; the unmeasured receiver/input
reachability prevents a stronger assertion. This narrows the brief's general
implementation path under an explicit controller ruling, not a finding that
the frozen observations are
unreachable in all rules.

The JavaMap/JavaList members, wrapper type tests and string forms remain actual
compatibility differences for synthetic or newly encountered sources. The
frozen `getClass()` result for a Java wrapper is **null**, not a class-name
object: that contract must be preserved if this surface is implemented later.
No new refusal or policy rejection is introduced, and no missing row is counted
as matched.

The controller also settled a future suffix implementation contract: measured
class-name prefix plus an opaque per-object token, with the JVM hash's exact
value deliberately unreproduced. No suffix implementation is required by the
current zero-resolved-used decision. The executed probe additionally records
that re-passing the same JS array through separate Java `getString` calls can
produce different suffixes; it does not establish cross-call identity stability.
That observation must be resolved before using the future contract as a parity
claim.

`java.getElements` keeps #105's ordinary HTML collection/node extraction,
selection, attribute and text behavior. Its whole-element scalar string form
also keeps the previous product behavior, including the recorded NativeArray
scalar-prefix difference. NativeArray JS `String` coercion is a distinct,
ordinary array operation; this decision does not replace it with the JVM form.

Anti-overengineering verdict: **Defer** the carrier. No resolved used observer
justifies an extra representation or bridge path. No Rust API, generated
binding, shared bridge framing, public host member, DOM behavior, storage or
configuration changes are needed.

## Evidence and re-derivation

Raw evidence root:
`C:/Users/17945/AppData/Local/liber-evidence/batch27/128/`.

- `ContainerOracle.kt`, `fixtures.json`, `run_probe.py`, `observed.json`,
  `manifest.json`: 55 executed synthetic observations through the actual frozen
  `AnalyzeRule`; the runner checks frozen Git-object source pins, compiled
  inputs, class hashes and toolchain hashes. It reuses the batch-26 #93 compiled
  frozen classes and compiles only this small harness. Compile/run both exit 0;
  **42 values and 13 recorded script exceptions**, not 55 parity passes.
- `count_sources.py`, `source-population.json`: counts over every source string,
  with the approved backup hash checked first.
- `run_source_observers.py`, `resolve_observers.js`,
  `resolved-observers.json`: AST classification of literal rule arguments and
  the comment containing `.size`. Acorn 8.15.0 is scratch tooling only; its
  version and integrity are pinned in `parser/package-lock.json`.
- `all_used_shapes.dart`, `classify_scripts.js`, `script-ast-shapes.json`:
  the complete 228-field population, retained rule-parser failures, historical
  101/225 subset, 104/228 tail/failure pool and separate 54-field unresolved-input
  diagnostic. These are syntactic diagnostics, not receiver/input analysis or
  conservative reachability residuals. Private text is passed only to scratch
  classification and never copied into the public tree or these reports.
- `review-repair-1/before/` and `review-repair-1/snapshot.json` preserve the
  reviewed document, comment, instruments and raw classifications unchanged.
  `review-repair-1/measure.py`, `aggregate.py` and `measurement-checks.json`,
  together with the root `determination-counts.json`, reproduce the corrected
  accounting, verify the 225 historical tail rows are unchanged and record the
  five synthetic diagnostic controls.
- `script-surface.log`: the unchanged #98 command rerun over the same artifact.

Host-JVM evidence is not Android-device evidence. App build, driven Windows
review, independent acceptance, integrated checks and CI belong to the
controller. This branch does not advance a platform or aggregate claim.

## Validation on this candidate

The following confirmed **CLI** results were recorded on the original candidate
`40a034eba61f63bb5b2f07aab139a92c4c27ed6d` from this same worktree; Dart MCP was
not available to this child. They are retained input-scoped evidence, not newly
rerun checks on the amended documentation. The correction reruns only the field
instrument, AST diagnostics and accounting controls; `lib/`, Rust and `test/`
remain byte-identical to the reviewed candidate and supplied base.

- `cargo build --locked --manifest-path packages/fjs/libfjs/Cargo.toml -j 2`:
  exit 0. The own-source DLL was copied to this worktree's
  `build/windows/x64/runner/Debug/fjs.dll`. Built/copied SHA256 both
  `7b7de8d82652d77d62966df43c5ec5b71317b554754ff4fc454954c1d9bb5290`.
- `cargo test --locked --manifest-path packages/fjs/libfjs/Cargo.toml -j 2`:
  exit 0, **643 passed / 0 failed / 0 ignored**. There is no carrier-specific
  Rust unit test because no carrier or Rust change is introduced.
- `flutter test test/html_get_elements_test.dart test/rule_field_review_test.dart test/source_host_surface_test.dart --concurrency=1 --reporter=expanded`:
  exit 0, **134 passed**, three normal teardowns and no Dart VM crash marker.
  This includes the existing NativeArray-prefix and map/list string mismatch
  guards; **134 is not a parity count**. Their printed actual values remain in
  `dart-affected.log`.
- `dart run tool/host_surface_gate.dart build/windows/x64/runner/Debug/fjs.dll`:
  exit 0, **106/106** checks true. No public member is added.

`validation.json` retains the actual command argument arrays, exit codes,
timestamps, copied-library binding and log names. The initial background native
build's raw log is also preserved; the tracked build command above verified its
successful final state. Flutter's dependency preparation rewrote seven generated
plugin files with line-ending-only changes; those unrelated generated bytes were
restored. No Dart/Rust/API/binding/dependency/configuration changes are committed,
and no new tests are needed for the recorded decision.

The exact candidate/source hashes, the single evidence-comment receipt and the
clean index/worktree status are in this lane's final binding manifest under the
raw evidence root. Independent review, integrated verification and release gates
remain controller-owned.
