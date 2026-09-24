# P5 audit — the v1-scope rows against Windows differential evidence

Ticket: the audit was run by the batch-14 controller on 2026-09-24 (no ticket; this document is the
record, and `docs/compatibility/delivery-phases.md` cites it). It answers one question against the
phase table's P5 exit criterion — *"for every in-v1 row: a differential fixture and a passing
comparison"* — and records the answer it found rather than the answer the route wanted.

**Verdict.** Every v1 differential fixture that exists **passes on Windows** on the integrated tree.
The P5 exit criterion is **not met**: 16 v1 capability rows have no differential fixture at all, and
one row's only evidence is a recorded report that no command re-derives. The differential contract is
explicit that this blocks the claim — *"a capability with no fixture is a declared coverage gap. A
gap blocks every aggregate claim that depends on that capability"* — so **no v1-scope compatibility
claim is recorded for Windows (or any platform) by this batch**. What is recorded is the gap list
below, with each row's owner, so the next batch can close rows instead of re-auditing.

## 1. Executed Windows differentials (all pass)

Tree: `master` `2ff2e0d`, native library `build/windows/x64/runner/Debug/fjs.dll`
sha256 `2cc5454f50cef752…`, controller-run on 2026-09-24. Commands are the ones the
capability rows' own tickets recorded; each row's verdict is the comparator's own.

| Corpus | Command | Windows result |
|---|---|---|
| SLICE-01 (first slice R2–R9) | `dart run tool/first_slice_replay.dart <dll> --out …` then `dart run tool/first_slice_compare.dart tool/first_slice/evidence/android-17-os4.0.0.31/golden.json …` | `status: pass`, **8 pass / 0 fail / 9 notCompared** |
| FIELDS-01 (result fields, content title, `canReName`, `wordCount`) | `dart run tool/result_field_replay.dart <dll> …` then `dart run tool/result_field_compare.dart tool/result_field_oracle/evidence/android-17-os4.0.0.31/golden.json …` | **8 pass / 0 fail / 6 notCompared** |
| REQUEST-01 v2 (charset decode, redirect rules, query bytes, page lists, defaults) | `dart run tool/nested_oracle_compare.dart --requests <dll> tool/nested_oracle/evidence/android-17-os4.0.0.31/request-oracle.json …` | **20 pass / 0 fail / 3 notCompared** (23 rows, 3 declared divergences) |
| HTML extraction corpus (45 cases, incl. the 4 rule-field rows) | `dart run tool/html_adapter_gate.dart <dll> tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json …` | **pass, 45 cases compared against the frozen golden** |
| Nested/shared JS scope | `dart run tool/nested_oracle_compare.dart <dll> tool/nested_oracle/evidence/android-17-os4.0.0.25/golden.json …` | `pass`, `countMatches`/`requestsMatch` true |
| Execution-model state | `dart run tool/state_oracle_compare.dart <dll> tool/nested_oracle/evidence/android-17-os4.0.0.25/state-expanded-golden.json …` | `pass`, 0 differences, 1 named `notCompared` |
| Replacement JavaScript | `dart run tool/replace_js_oracle/compare.dart <dll> tool/replace_js_oracle/evidence/android-17-os4.0.0.31/golden.json …` | **11 pass / 0 fail / 2 notCompared** |
| reSegment stage | `flutter test test` (`test/content_re_segment_differential_test.dart`, JVM-host golden) | pass (part of the 724-test suite) |
| Runtime gates (per-platform row set) | `python tool/ci_runtime.py windows x86_64-pc-windows-msvc` | **16 rows, exit 0** (manifest in `.ci-results/`) |

The `notCompared` entries are the contract's own recorded categories (platform-generated headers,
provenance fields, the execution-model divergence, the three REQUEST-01 divergences); each carries
its reason in the report JSON, and none of them is inside a claimed row.

Outside this table but re-executed in the same batch: the **WebView destination corpus on Windows**
(14 fixtures through one binary, sampled equal around every fixture — 13 `match`, `WV-14`
`policy-rejected` because WebView2 cannot surface a certificate error), with the manifest rewritten to
the current revision so the committed rows describe it; the Android destination rows cannot be
re-collected without the handset and are refused by name by the comparator until they are.

## 2. A row whose evidence is a recorded result, not a re-runnable comparison

| Row | Owner | State |
|---|---|---|
| User replace rules on TOC titles and content | #17 | `tool/replace_rule_oracle/evidence/comparison.json` records the 2026-09-21 handset run (13 pass / 0 fail / 2 notCompared). The capture it came from was never committed, so no command re-derives it; the comparator now refuses that file by name and says what a golden is (#70, batch 14). The rows stay that run's result. |

## 3. Declared coverage gaps (no differential fixture)

Each row below is implemented and covered by tests or a gate (the capability matrix's ✅), but the
contract wants a frozen comparison, and there is none. The owner column is the ticket that would
build it.

**Batch 15 measured all seventeen families against the operator's used set** (`dart run
tool/source_triage.dart --usage <backup.zip>`, `#74`): **no family is unused** — the used set calls every
one of them, from `ajaxAll` and `java.connect(` at 1 of 150 up to `loginCheckJs` at 9 of 150 — so
`decision 18`'s "zero usage retires a row" route retires nothing here. The operator signed this
disposition list (2026-09-24):

- **Build a differential fixture** — the rows below whose product claim matches the frozen: the
  request/login/limiter families, the rule-derived families, the multi-URL shapes, the hatches, the
  emulated members and the cleanup rules. **`#74` owns them** (wave 2 builds them family by family).
- **`policy-rejected`** — the TLS row: the baseline trusts every certificate unconditionally
  (`HttpHelper.kt:63-65`), so the product's validation default plus the per-source confirmation is a
  *deliberate* divergence with no parity to compare; the divergence is recorded in ADR 0011 §5 and the
  differential contract, and `#75`'s WebView halves now reach the same confirmation.
- **Product-owned, not a differential row** — host-surface cleanup on delete/re-point and the bound on
  persisted growth (`#36`/`#37`): the frozen has no counterpart, and the same is true of the JSON
  pipeline (#29) and libfjs's runtime tests (#35), which are excluded below.
- **Implemented instead of retired** — the `book`/`chapter` variable members: the one used call site
  made "record a divergence" the wrong answer, and `#76` implemented the whole six-member family
  (batch 15).

| v1 row | Owner | What exists today |
|---|---|---|
| Login flow (`loginUrl`, `loginUi`, `loginCheckJs`) | #59/#60 | product tests + a driven run (batch 11); the UI half of `loginUi` is `policy-rejected` (a visible page cannot be driven headlessly) |
| TOC markers (`updateTime`, `isVolume`, `isVip`, `isPay`) | #13 | extracted, persisted (schema v6) and shown; product tests |
| `bookUrlPattern` | #61 | product tests + a driven run |
| Source variables (`getVariable`/`setVariable`) | #59 | host-surface gate + product tests |
| Book and chapter variables (`book`/`chapter` `.getVariable`/`.putVariable`/`.variable`) | #76 | implemented in batch 15 over `books.variable`/`chapters.variable`, gate-checked — the gap that remains is the differential fixture, not the capability |
| Local `jsLib` shared scope | #13 | product tests |
| Per-source concurrency and `concurrentRate` | #42 | the limiter around every source request; the frozen multi-URL `nextTocUrl` branch is recorded unexercised |
| `enabledCookieJar` parity | #42 | product tests; the session/persistent split divergence is recorded |
| `java` multi-URL `ajax`/`ajaxAll`, header-string `connect`, `getHeaderMap` | #43 | source-derived Windows tests + host gate; `docs/compatibility/host-surface-43.md` states no frozen golden was executed |
| `toNumChapter` Chinese numerals | #43 | product tests (source-derived) |
| JSONPath filters and slices | #44 | `tool/jsonpath_probe/` (a host probe of the frozen library, transcript only) + product tests |
| Multi-URL page results and `imageStyle` | #14/#67 | product tests and widget rows; the frozen-device layout rows stay `not-run` (no handset in batch 14) |
| User-confirmed browser and captcha hatches | #32 | product tests + host gate; the visible-page rows are `policy-rejected` for the same reason as `loginUi` |
| Named refusals, emulated `androidId`/`getWebViewUA`, bounded logs and toasts | #31 | host gate; the emulated members are named divergences by design |

| Disposition | Families |
|---|---|
| Build a fixture (`#74` wave 2) | login (non-UI), TOC markers, `bookUrlPattern`, source variables, book/chapter variables, local `jsLib`, concurrency and `concurrentRate`, `enabledCookieJar`, the `java` multi-URL family, `toNumChapter`, JSONPath, multi-URL page results, the hatches' non-UI half |
| `policy-rejected` | TLS per-source exception; the `loginUi` and hatch *visible-page* halves |
| Out of the differential set | host-surface cleanup/growth (`#36`/`#37`) |
| Implemented (was a gap) | book/chapter variable members (`#76`) |

Not gaps, for the record: the JSON pipeline reaching the shelf and the reader (#29) is a product
path with no frozen stage; libfjs's runtime tests (#35) are CI gates, not compatibility rows.

## 4. What the next batch should do with this

1. Build the signed fixture list above (`#74` wave 2), cheapest first: the request/host-surface
   families have device harnesses already (`tool/nested_oracle/RequestOracle.java` and
   `tool/html_oracle/`), and one JVM host-surface sweep can cover login (non-UI), source variables,
   local `jsLib`, concurrency, the `java` family and `toNumChapter` together.
2. The device-backed rows (#66's list read, #67's `imageStyle` layouts, #75's Android destination row)
   need the handset attached; `adb devices` was empty at this audit, so they stay `not-run`.
3. The five-platform aggregate stays blocked on #56 regardless of this document.
