# JSONPath probe (ticket #44)

The frozen `AnalyzeByJSonPath.kt` wraps **json-path 2.9.0** (`gradle/libs.versions.toml:22`)
directly — `JsonPath.parse(json).read(rule)` — so the accepted rule grammar is that
library's, not a remembered one. This directory runs the real jar over a fixed document set
and records what it answers, so the JSON adapter in `lib/source/json_source_rules.dart` is
written against measured behaviour instead of assumption.

`transcript.txt` is that record. It is the evidence behind every "the frozen library does X"
comment in the adapter, the rule-level test expectations in `test/json_source_rules_test.dart`,
and the JSONPath row of `docs/compatibility/book-source-capability-matrix.md`.

## Running it

```sh
bash tool/jsonpath_probe/run.sh    # fetches the jars, checks the hashes, rewrites transcript.txt
```

Requires `curl`, `sha256sum` and a JDK 8+ (`javac`/`java`). The jars are **not** committed;
`run.sh` downloads them from Maven Central and verifies them against `jars.sha256`, which is
the pin:

| Artifact | sha256 |
|---|---|
| `com.jayway.jsonpath:json-path:2.9.0` | `11a9ee6f88bb31f1450108d1cf6441377dec84aca075eb6bb2343be157575bea` |
| `net.minidev:json-smart:2.5.0` | `432b9e545848c4141b80717b26e367f83bf33f19250a228ce75da6e967da2bc7` |
| `net.minidev:accessors-smart:2.5.0` | `12314fc6881d66a413fd66370787adba16e504fbf7e138690b0f3952e3fbd321` |
| `org.slf4j:slf4j-api:2.0.11` | `ce0e71d673acb9036bb55d0244b261cf033f8e4c1245f14f931dfb1937dd4c95` |
| `org.ow2.asm:asm:9.6` | `3c6fac2424db3d4a853b669f4e3d1d9c3c552235e19a319673f887083c2303a1` |

Each line of the transcript is `rule <TAB> ok|error <TAB> result or exception`, with container
types spelled out so that the difference between a flat list of matches and a single value is
visible. The four sections are the frozen rules the used sources reach (`main`), the corners an
implementation has to get right (`corners`), what a scan does when its target token is not the
leaf (`scan`), and the `=~` full-match corners (`regex`).

## What the adapter took from it

| Form | Frozen behaviour (transcript) | In the adapter |
|---|---|---|
| `$.data[?(@.hasContent==1)].content` | matches the row whose value is the *string* `"1"` too | reproduced via the `NumberNode`/`StringNode` comparison rules |
| `.[?(@.title)]` | `PathCompiler` prefixes `$.`, so it is the recursive `$..[?(@.title)]` | `extract` routes a dot-leading rule to the path reader |
| `[1:3]`, `[:2]`, `[2:]`, `[:-2]` | `ArraySliceToken`'s three operations | reproduced, including `SLICE_BETWEEN` not resolving a negative end (`[1:-1]` is empty) |
| `[1:3:2]` | accepted, third field ignored | reproduced, named in a test |
| `[::2]`, `[:]` | `InvalidPathException` | refused by name |
| `$.meta[1:2]` | `PathNotFoundException` ("can only be applied to arrays") | a named `FormatException` (the frozen *reader* swallows it into a null — a recorded divergence in the failure's shape) |
| `[?(@.a exists true)]` | matches nothing: the operand is the path's value, not its existence | reproduced |
| `=~ /a\|ab/`, `=~ /p4$/` | `Matcher.matches` — the whole input, with backtracking | reproduced through the Java-pattern port plus an anchoring group |
| `$..[0].content`, `$..*.content` | decided by `ScanPathToken.walkArray`'s element-index guard | refused by name |
| `===`, `contains`, `type`, `all`, `subsetof`, `anyof`, `noneof` | in the frozen operator set | refused by name (the adapter runs the operator set the ticket names) |
| a rule whose path matches several values | `AnalyzeByJSonPath.getString` joins them with `"\n"` | `JsonSourceRules._fieldText` joins the same way |

The library sources the adapter's comments quote
(`PathCompiler`, `PathToken`, `ArrayPathToken`, `ArraySliceOperation`, `ScanPathToken`,
`FilterCompiler`, `ValueNodes`, `EvaluatorFactory`, `RelationalOperator`) come from the
`json-path-2.9.0-sources.jar` of the same release; they are not committed here.
