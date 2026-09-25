# #79's frozen-side limit probe — harness built, device row not-run

The probe this document describes exists and builds; **its device row has not been executed**, because
`adb devices` lost the handset `5615f742` before the harness was ready and never recovered it during the
lane. Nothing here is an observation of the frozen engine at its limit, and no parity verdict is recorded.
The first section that claims device facts only does so after the run; until then the run section is the
not-run table at the end.

## What the probe is, and why it drives that entry

Ticket #79 asks what the **frozen** engine does when a script accumulates to its limit, because the
product's engine (QuickJS, 64 MiB cap, `lib/source/js_source_runtime.dart:55`) can lose the out-of-memory
*report* and show `Runtime error: null` instead (limit still enforced). The frozen baseline's engine is
Rhino, and it caps nothing itself: `RhinoScriptEngine`'s global `ContextFactory` sets
`instructionObserverThreshold = 10000`, `maximumInterpreterStackDepth = 1000` and interpreted mode
(`RhinoScriptEngine.kt` init), and `RhinoContext.ensureActive` only asks a coroutine context for
cancellation (`RhinoContext.kt`). There is no heap cap in the frozen tree, so **the limit is the target
app's Java heap** and the interesting outcome is the report losing itself or the process dying.

Entry driven: a **rule-level `@js:` field**, through `AnalyzeRule.getString(rule, content, isUrl)`:

- `AnalyzeRule.splitSourceRule` matches `@js:` with `AppPattern.JS_PATTERN` (`AppPattern.kt:8`) and builds
  a `SourceRule(body, Mode.Js)` (`AnalyzeRule.kt:471-520`);
- the field then runs `Mode.Js -> evalJS(rule, result)` (`AnalyzeRule.kt:290`, the `@js:`-only field's
  branch) — that is `AnalyzeRule.evalJS` (`AnalyzeRule.kt:749`), which compiles through
  `RhinoScriptEngine.compile` and evaluates through `RhinoCompiledScript.eval`
  (`modules/rhino/.../RhinoCompiledScript.kt`), falling through to `RhinoScriptEngine.eval`'s own
  `try/catch (RhinoException)` mapping;
- `result` is the field's input value, exactly as `lib/source/rule_field.dart` describes the product's
  model of this rule form ("the frozen `@js:`-only rule", "exactly as the frozen `evalJS(rule, result)`
  does").

The batch briefing's steer named `AnalyzeUrl.evalJS` for this row; that method is the same engine, the
same scope construction and the same error mapping, but it serves a URL's inline `{{js}}` segments and the
request options (`AnalyzeUrl.kt:340`), not a source's own rule field. The rule-level entry is the one a
Book Source's rule reaches, so it is the behaviour a source log records. This is a correction to the
briefing's premise, not a new decision: `AnalyzeUrl.evalJS` remains undriven and is named as not-run.

An accumulating failure does not reach a source log by itself. The frozen caller-side rendering is
`Debug.log(debugSource, it.stackTraceStr, state = -1)` (`Debug.kt:137` and neighbours) with
`Throwable.stackTraceStr` = `stackTraceToString()` (`ThrowableExtensions.kt:5`). The harness therefore
records the observed throwable *and* that exact string, obtained from the frozen
`io.legado.app.utils.ThrowableExtensionsKt.getStackTraceStr`, so the row says what the source log would
show rather than a paraphrase of it.

## The row set, and its order

`tool/nested_oracle/limit-fixtures.json` (`LIMIT-01`), driven in declared order by
`tool/nested_oracle/LimitOracle.java`:

| Row | Rule | Purpose |
|---|---|---|
| `preflight-array-fill` | `@js:typeof Array.prototype.fill` | the accumulating shape is array growth, not a missing ES6 method |
| `preflight-result-binding` | `@js:String(result).length` | the drive binds `result` to the field's content |
| `control-throw-null` | `@js:throw null` | #79's control: the frozen engine's own shape for a thrown null |
| `probe-accumulate-to-limit` | `@js:var blocks = []; while (true) { blocks.push(new Array(10000).fill(123)); }` | **destructive**: #79's measured shape verbatim, through `AnalyzeRule.evalJS` |
| `after-limit-engine-usable` | `@js:1 + 1` | the frozen analogue of #79's `afterGcUsable`: is the path usable after the limit, and what is the heap then |

The destructive row is the last accumulating row and the only unbounded one; nothing else in the process
bounds it. The single post-probe row is one tiny evaluation, and both the report and the journal already
carry the probe's outcome before it runs.

Durability: every stage is appended to
`/sdcard/Android/data/io.legado.app.debug/files/limit-oracle.journal.ndjson` as single-line JSON and
`flush()`ed and `fd.sync()`ed before the next stage starts, and the report
(`.../files/limit-oracle.json`) is written once at the probe row and again at the end. A death inside the
accumulating row therefore leaves `destructive-begin` (with the rule text and the heap before it) as the
last journal line, and the stages before it are complete.

## Commands (the runner wiring)

```text
pwsh tool/nested_oracle/build.ps1 -OutputDirectory <fresh-dir> -JavaHome C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8
MSYS_NO_PATHCONV=1 adb -s 5615f742 install -r -t <fresh-dir>/nested-oracle.apk
MSYS_NO_PATHCONV=1 adb -s 5615f742 shell svc power stayon true
MSYS_NO_PATHCONV=1 adb -s 5615f742 shell am force-stop io.legado.app.debug
MSYS_NO_PATHCONV=1 adb -s 5615f742 shell am instrument -w -r io.liber.oracle.nested/io.liber.oracle.nested.LimitOracle
MSYS_NO_PATHCONV=1 adb -s 5615f742 pull /sdcard/Android/data/io.legado.app.debug/files/limit-oracle.journal.ndjson <capture>/limit-oracle.journal.ndjson
MSYS_NO_PATHCONV=1 adb -s 5615f742 pull /sdcard/Android/data/io.legado.app.debug/files/limit-oracle.json <capture>/limit-oracle.json
```

The journal pull is unconditional: it is the record when the instrumentation reports a failure because
the process died at the limit. A fresh `sqlite`/app-state change is not needed — the harness drives
reflection only, and no frozen class is rebuilt.

## Build verification (executed)

| Item | Value |
|---|---|
| `tool/nested_oracle/LimitOracle.java` | sha256 `5c95d98ffd86ddd83db7cb21eb2d66cd06cee3963b416fbcdfcb4fe529d96761` |
| `tool/nested_oracle/limit-fixtures.json` | sha256 `eddb59d4a238956015a58687c1ee193f5b05a9063a76d34e4d4ecae1704d76e0` |
| `tool/nested_oracle/AndroidManifest.xml` | sha256 `fc5a83c311bce349d97c00430cf03bb4cf3311eff88add650c8a91a370b0dc60` |
| `tool/nested_oracle/build.ps1` | sha256 `a3aa0cb895aca8ee04735e0ffa57c2b5e4684dda20288d3142761eff4152f457` |
| built APK (last build) | sha256 `656d4e3b8e80a46ce44e6b9162ce2ad712ecf8da4f2fafb1ea8ab896f45207cf` |
| bundled asset vs committed fixture | identical (`eddb59d4…`), and the harness records the loaded asset's own sha256 in `harness-begin` |
| javac | exit 0; the one known `-source 8` bootstrap-classpath warning; `LimitOracle.class` and the `LimitOracle` instrumentation entry present in the dex/manifest |

APK hashes are not byte-stable between builds (apksigner), as this harness's own manifest already records
for the other oracles.

## Reflection targets verified offline (executed)

The harness reaches the frozen tree by reflection, so no compiler checks its class and member names. Each one
was checked against the pinned frozen APK's own bytes: `oracle-apks-verified/app.apk` hashes to
`cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6` (the base APK the installed
`io.legado.app.debug` was verified against), and the extracted dexes under `frozen-dex/` match it —
`classes8.dex` → `323557492225e42654fa46a109eeb929944c298b8ea144c30697bb6fc161c14f` and `classes10.dex` →
`f83b0b74729b5762ea90c0ad483633408229948c0433de677a024354eb35cbde`, both identical through
`unzip -p app.apk <dex>` and `sha256sum`. `dexdump` then confirmed:

| Reflected member | dex prototype | dex |
|---|---|---|
| `AnalyzeRule.<init>` | `(Lio/legado/app/model/analyzeRule/RuleDataInterface;Lio/legado/app/data/entities/BaseSource;)V` | classes8 |
| `AnalyzeRule.getString` | `(Ljava/lang/String;Ljava/lang/Object;Z)Ljava/lang/String;` | classes8 |
| `AnalyzeRule.setContent` | `(Ljava/lang/Object;Ljava/lang/String;)Lio/legado/app/model/analyzeRule/AnalyzeRule;` | classes8 |
| `AnalyzeRule.evalJS` | `(Ljava/lang/String;Ljava/lang/Object;)Ljava/lang/Object;` | classes8 |
| `BookSource.<init>` | `()V` | classes8 |
| `BookSource.setBookSourceUrl`, `setJsLib` | `(Ljava/lang/String;)V` | classes8 |
| `RuleData.<init>` | `()V` | classes8 |
| `ThrowableExtensionsKt.getStackTraceStr` | `(Ljava/lang/Throwable;)Ljava/lang/String;` | classes10 |

Command shape: `"$LOCALAPPDATA/Android/Sdk/build-tools/35.0.1/dexdump.exe" <dex>`, then the class
descriptor's section read for the member's `name`/`type` pair. This verifies the names, not the behaviour:
the behaviour is what the not-run device row owes.

## Not run

| Item | State | Reason |
|---|---|---|
| Install of the harness APK on `5615f742` | **not-run** | no device attached (`adb devices` empty; `adb kill-server`/`start-server` retried) |
| `LimitOracle` instrumentation row set (all five rows) | **not-run** | same |
| Device facts (Android release, System WebView version, heap class) from this run | **not-run** | same; the harness records them in its `device` stage when it runs. Nothing in this lane read a property from the handset |
| Re-verification of the installed `io.legado.app.debug` bytes | **not-run** | no device attached; the pinned APK (`cc99040c…`) is the basis used for the offline dex check above |
| Observable outcome of `control-throw-null` | **not-run** | same |
| Observable outcome of `probe-accumulate-to-limit` | **not-run** | same |
| `AnalyzeUrl.evalJS` variant of the accumulating row | **not-run** | deliberate: the rule-level entry is the driven one, and the destructive step runs once |
| Parity verdict | **unobservable so far** | no execution of the frozen engine at its limit; #79's question stays open |
