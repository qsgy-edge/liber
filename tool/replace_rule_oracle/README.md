# Replace-rule oracle corpus

This corpus prepares the frozen-side entry for ticket #17 without manufacturing a
frozen result. The inputs are pinned to the frozen Legado baseline and name the
exact entry points that a future Android oracle must call:

- `ContentProcessor.getContent` for the chapter body;
- `BookChapter.getDisplayTitle` for a chapter title;
- the `ReplaceRuleDao` selection queries for scope and ordering.

`fixtures.json` deliberately contains inputs and row metadata only. It has no
hand-authored expected values and no committed golden. The Android
`ContentProcessor` entry is **not-run**, owned by #38; #54 owns the handset in
batch 9. A host implementation of the algorithm would not be independent
frozen evidence, so it is not used as a comparator.

The comparison boundary is the processed content returned before
`ContentProcessor.kt:177-198` performs final paragraph shaping. This keeps
#50's reader paragraph trimming, blank-line removal, and indentation out of a
replace-rule verdict. The title path is compared separately at
`BookChapter.getDisplayTitle`.

The corpus covers the requested rows:

| Row | Fixture | Status | Frozen entry or reason |
|---|---|---|---|
| No rules | `no-rules` | `not-run` | `ContentProcessor.getContent` and `BookChapter.getDisplayTitle` |
| Content-only | `content-only` | `not-run` | `ContentProcessor.getContent` content rule list |
| Title-only | `title-only` | `not-run` | `BookChapter.getDisplayTitle` title rule list |
| Both paths | `both` | `not-run` | Both entry points in one case |
| Regex and literal | `regex`, `literal` | `not-run` | `RegexExtensions.replace` and literal branch |
| Scope by name and origin | `scope-name-origin` | `not-run` | `ReplaceRuleDao.findEnabledBy*Scope` |
| Exclude scope by name and origin | `exclude-scope-name-origin` | `not-run` | `ReplaceRuleDao.findEnabledBy*Scope` |
| Ordering and duplicate order | `ordering` | `not-run` | `ORDER BY sortOrder` |
| Duplicated title | `duplicated-title` | `not-run` | `ContentProcessor.kt` duplicate-title branch |
| Re-segmentation interaction | `re-segment-interaction` | `not-run` | `ContentHelp.reSegment` before conversion and rules |
| Simplified/traditional conversion | `conversion-t2s`, `conversion-s2t` | `not-run` | `BookChapter` and `ContentProcessor` conversion boundary |
| Timeout attribution | `timeout` | `notCompared` observation inside `not-run` row | Frozen restart/stack-trace side effect is not reproduced by approved product behavior |
| Refusals | `refusal` | `not-run` | Device observation required for frozen comparison; product refusals remain named in its tests |

The fixture is an input contract, not a compatibility claim. A future device
entry must produce the golden from the frozen APK, record its APK and fixture
hashes, compare the processed-stage strings without broad normalization, and
keep every unavailable or divergent observation explicit.
