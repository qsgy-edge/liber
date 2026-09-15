# Legado Data Migration Contract

Evidence baseline: `14dd24945b2914ce2708b8abaa4ee67ceef892af`  
Reviewed: 2026-08-18 UTC  
Independent review verdict: **PASS WITH CORRECTIONS**; all listed corrections are incorporated below.

## Verdict

- **CONFIRMED** — The frozen Legado baseline exposes two useful explicit JSON surfaces: `BookSource` objects/arrays and `BookProgress` objects. The first-party API documents both shapes and maps them directly to the corresponding data classes ([api.md](/D:/GithubRepositories/Android/legado/api.md:14), [api.md](/D:/GithubRepositories/Android/legado/api.md:182)).
- **CONFIRMED** — The UI `books.json` export is not a migration format. It writes only `name`, `author`, and `intro`; import reads only name/author, then searches enabled sources again ([BookshelfViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/main/bookshelf/BookshelfViewModel.kt:102), [BookshelfViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/main/bookshelf/BookshelfViewModel.kt:156)).
- **CONFIRMED** — A normal full backup is a root-level ZIP containing direct entity JSON arrays plus Android SharedPreferences `config.xml`. It has no manifest or backup-format version and is therefore a frozen-baseline import source, not a stable protocol ([Backup.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Backup.kt:47), [Backup.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Backup.kt:120)).
- **INFERENCE** — Liber should accept the frozen Legado surfaces through an adapter, then store a platform-neutral, explicitly versioned UTF-8 JSON contract. Liber must not use Legado's Room entities, Android paths, or backup ZIP layout as its own persistence model.

## Confirmed Migration Surfaces

### Book Sources

- **CONFIRMED** — UI export writes `shareBookSource.json` as a top-level array of selected `BookSource` objects; the shared serializer uses UTF-8 and indented Gson JSON ([BookSourceViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/book/source/manage/BookSourceViewModel.kt:129), [GSONExtensions.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/utils/GSONExtensions.kt:109)). There is no envelope or version marker.
- **CONFIRMED** — UI import accepts a direct object, array, HTTP(S) URL, Android URI, or a `sourceUrls` aggregate object. URL and URI payloads are parsed as arrays ([ImportBookSourceViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/association/ImportBookSourceViewModel.kt:131), [ImportBookSourceViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/association/ImportBookSourceViewModel.kt:189)).
- **CONFIRMED** — UI JSON parsing checks non-empty `bookSourceUrl`, but does not require a non-empty name at that boundary ([ImportBookSourceViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/association/ImportBookSourceViewModel.kt:145)). The Web API requires both `bookSourceName` and `bookSourceUrl` ([BookSourceController.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/api/controller/BookSourceController.kt:29)). Final UI insertion additionally rejects domains on Legado's built-in policy list ([SourceHelp.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/source/SourceHelp.kt:79)).
- **CONFIRMED** — `bookSourceUrl` is the Room primary key and insertion uses `REPLACE` ([BookSource.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/BookSource.kt:33), [BookSourceDao.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/dao/BookSourceDao.kt:258)). UI comparison preselects new sources and sources with a later `lastUpdateTime` ([ImportBookSourceViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/association/ImportBookSourceViewModel.kt:208)).
- **CONFIRMED** — Import settings optionally preserve local name, group, and enabled flags; `customOrder` is always copied from the existing source, independent of those settings ([ImportBookSourceViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/association/ImportBookSourceViewModel.kt:89)).

### Bookshelf List

- **CONFIRMED** — `books.json` contains only `name`, `author`, and `intro` ([BookshelfViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/main/bookshelf/BookshelfViewModel.kt:113)).
- **CONFIRMED** — Import accepts an array or an absolute URL returning that array. It requires a non-empty name, defaults author to an empty string, skips an existing `(name, author)`, and searches all enabled sources before adding a result ([BookshelfViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/main/bookshelf/BookshelfViewModel.kt:131), [BookshelfViewModel.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/ui/main/bookshelf/BookshelfViewModel.kt:161)).
- **CONFIRMED** — The importer does not consume the exported `intro`. It also cannot preserve source identity, `bookUrl`, groups, cover/custom metadata, local paths, or reading progress.

### Full Book and Progress APIs

- **CONFIRMED** — The Web API accepts a complete `Book` JSON object and returns the full bookshelf ([api.md](/D:/GithubRepositories/Android/legado/api.md:118), [api.md](/D:/GithubRepositories/Android/legado/api.md:135)). `Book.bookUrl` is the primary key, while `(name, author)` is also unique; DAO insertion uses `REPLACE` ([Book.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/Book.kt:34), [BookDao.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/dao/BookDao.kt:144)).
- **CONFIRMED** — `BookProgress` has six properties: `name`, `author`, chapter index, character offset, update time, and nullable chapter title ([BookProgress.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/BookProgress.kt:3)). Web save locates a book by `(name, author)` and overwrites all four progress values without a forward-only comparison ([BookController.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/api/controller/BookController.kt:253)).
- **UNCONFIRMED** — The five non-null Kotlin properties are not proven to be required at the incoming Gson JSON boundary because the controller performs no explicit presence validation. Liber v1 may require them, but that is a Liber contract decision.
- **CONFIRMED** — `SaveBookProgress` exists in the Content Provider request enum and insert branch, but no URI is registered for it, so it is unreachable at this baseline ([ReaderProvider.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/api/ReaderProvider.kt:26), [ReaderProvider.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/api/ReaderProvider.kt:33)).

### WebDAV Progress

- **CONFIRMED** — Progress files live under `bookProgress/` and serialize `BookProgress` JSON; the body contains name/author, so the sanitized filename is not the sole identity ([AppWebDav.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/AppWebDav.kt:41), [AppWebDav.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/AppWebDav.kt:257)).
- **CONFIRMED** — Bulk download applies only a lexicographically farther `(chapterIndex, chapterPosition)` and uses remote modification time plus local `syncTime` to skip stale files ([AppWebDav.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/AppWebDav.kt:301), [AppWebDav.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/AppWebDav.kt:318)).
- **CONFIRMED** — This format has no `bookUrl` or source identity. Same-name, same-author books share its logical identity, so it can supplement progress but cannot establish bookshelf identity.

### Full Backup and Restore

- **CONFIRMED** — Candidate root files are enumerated by `backupFileNames`; entity files are omitted when their source list is empty, and the ZIP helper tolerates absent files ([Backup.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Backup.kt:47), [Backup.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Backup.kt:230), [ZipUtils.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/utils/compress/ZipUtils.kt:168)).
- **CONFIRMED** — `bookshelf.json`, `bookGroup.json`, and `bookSource.json` directly serialize full Room entity arrays ([Backup.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Backup.kt:120)).
- **CONFIRMED** — Restore first partitions books by `bookUrl`: existing rows use `update`, new rows use `insert` ([Restore.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Restore.kt:100), [Restore.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Restore.kt:115)). It does not compare timestamps or forward progress.
- **CONFIRMED** — A second conflict exists: because `(name, author)` is unique and the new-row path uses `REPLACE`, a different `bookUrl` with the same name/author can replace the existing row, including its source and progress ([Book.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/Book.kt:36), [Restore.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Restore.kt:122), [BookDao.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/dao/BookDao.kt:144)).
- **CONFIRMED** — Local-book restore can be skipped; otherwise only the cover cache path is recomputed. Original file/content URIs remain in the entity, while book bytes are not ZIP members ([Restore.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Restore.kt:110), [BackupConfig.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/BackupConfig.kt:137)).
- **CONFIRMED** — Room schema 75 declares its own schema `formatVersion` and database `version`, but the schema file is not a backup member. Those values are not a backup-format version ([75.json](/D:/GithubRepositories/Android/legado/app/schemas/io.legado.app.data.AppDatabase/75.json:2)).

## Field and Format Matrix

| Surface | Container | Identity | Boundary requirements | Classification |
|---|---|---|---|---|
| Book Source UI | JSON object/array, URL, URI, or `sourceUrls` aggregate | `bookSourceUrl` | UI parser: non-empty URL; final insert also applies domain policy | **CONFIRMED explicit interchange** |
| Book Source Web API | JSON object/array | `bookSourceUrl` | Non-empty URL and name | **CONFIRMED explicit interchange** |
| Books list UI | UTF-8 JSON array | `(name, author)` for skip/search | Name non-empty; author defaults empty | **CONFIRMED explicit but lossy** |
| Full `Book` API | Entity-shaped JSON | Primary `bookUrl`; unique `(name, author)` | No versioned interchange schema | **CONFIRMED explicit API, internal shape** |
| `BookProgress` | JSON object | `(name, author)` | Six-property shape confirmed; incoming requiredness unconfirmed | **CONFIRMED shape, partially unconfirmed validation** |
| Full backup | Root-level ZIP with JSON arrays and `config.xml` | Per-entity Room keys | Optional files, no manifest/version | **CONFIRMED internal snapshot** |
| Room schema 75 | Room schema JSON, not exported | Room table keys | Not applicable | **CONFIRMED internal schema** |

## Losses and Platform-Specific Data

- **CONFIRMED** — A local `Book.bookUrl` stores an Android file path or content URI ([Book.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/Book.kt:42), [LocalBook.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/model/localBook/LocalBook.kt:106)). The normal backup does not contain the referenced book file, so another platform must ask the user to relink it.
- **CONFIRMED** — The normal backup list omits `BookChapter`, `Cookie`, and `Cache` tables ([Backup.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/storage/Backup.kt:47), [BookChapter.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/BookChapter.kt:42), [Cookie.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/Cookie.kt:8), [Cache.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/Cache.kt:8)). Consequently it cannot preserve chapters, chapter variables, downloaded content, persistent cookies, source cache variables, or cached login state.
- **CONFIRMED** — Session cookies are memory-only, while persistent cookies are written through `cookieDao` ([CookieManager.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/http/CookieManager.kt:45), [CookieStore.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/help/http/CookieStore.kt:30)). Neither is in the normal backup file list.
- **CONFIRMED** — Book-level `variable` is inside the full `Book` entity and can be preserved opaquely; chapter-level `variable` is lost with the omitted chapter table ([Book.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/Book.kt:115), [BookChapter.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/entities/BookChapter.kt:58)).
- **CONFIRMED** — Custom groups are bit flags and may use `Long.MIN_VALUE` as the 64th bit. Migration must not filter custom groups using `groupId > 0` alone ([BookGroupDao.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/dao/BookGroupDao.kt:70), [BookGroupDao.kt](/D:/GithubRepositories/Android/legado/app/src/main/java/io/legado/app/data/dao/BookGroupDao.kt:95)).
- **UNCONFIRMED** — No first-party source promises forward compatibility for the entity JSON files in a backup ZIP. Direct entity serialization and the absence of a backup version are evidence against assuming it.

## Recommended Liber Contract

**INFERENCE — Use one versioned UTF-8 JSON document:**

```json
{
  "format": "liber-legado-migration",
  "version": 1,
  "sourceBaseline": "14dd24945b2914ce2708b8abaa4ee67ceef892af",
  "bookSources": [
    { "bookSourceUrl": "https://example", "bookSourceName": "Example" }
  ],
  "books": [
    {
      "legacyKey": "sha256:<original-legado-bookUrl>",
      "sourceRef": "https://example",
      "sourceBookUrl": "https://example/book/1",
      "localFileName": null,
      "name": "Book",
      "author": "Author",
      "kind": null,
      "customTag": null,
      "coverUrl": null,
      "customCoverUrl": null,
      "intro": null,
      "customIntro": null,
      "charset": null,
      "type": 0,
      "latestChapterTitle": null,
      "latestChapterTime": 0,
      "totalChapterNum": 0,
      "wordCount": null,
      "canUpdate": true,
      "groups": ["Reading"],
      "order": 0,
      "bookVariable": null,
      "progress": {
        "chapterIndex": 0,
        "chapterPosition": 0,
        "chapterTitle": null,
        "updatedAt": 0
      }
    }
  ]
}
```

### Normative Rules

1. **INFERENCE** — Require `format`, integer `version`, `sourceBaseline`, `bookSources`, and `books`; reject unsupported major versions.
2. **INFERENCE** — Preserve each accepted Book Source as a semantic JSON object, including unknown fields. Liber v1 requires non-empty string URL and name even though the Legado UI parser itself requires only URL.
3. **INFERENCE** — Network books use `(sourceRef, sourceBookUrl)` as migration identity. Same-name/author books from different sources may remain distinct in Liber.
4. **INFERENCE** — Local books never carry the Android path/URI into Liber. Store a SHA-256 correlation key and original filename, preserve metadata/progress, and mark content unresolved until the user relinks a file.
5. **INFERENCE** — Resolve every custom bit present in `Book.group` against `bookGroup.json`, including `Long.MIN_VALUE`; exclude Legado's synthetic negative group IDs that are not bit flags. Persist sorted unique group names, not numeric IDs.
6. **INFERENCE** — Preserve chapter index, character position, title, and update time. Do not treat `syncTime` as reading position.
7. **INFERENCE** — Import is idempotent. Source replacement requires explicit approval; shelf membership unions; imported metadata fills blanks but does not erase newer edits; progress advances only when `(chapterIndex, chapterPosition)` is greater, with timestamp as a tie-breaker.
8. **INFERENCE** — Treat all imported source scripts, headers, URLs, comments, and variables as untrusted data. Migration parsing never executes them.
9. **INFERENCE** — Liber v1 explicitly excludes cookies, login/cache state, chapter/cache data, Android settings, and local file bytes. Future inclusion requires a separate versioned security and portability contract.

## Required Fixtures and Tests

All items below are **INFERENCE** from the proposed Liber contract, not established Legado requirements.

1. Book Source object/array fixtures with nested rules, nulls, booleans, large integers, unknown fields, and non-ASCII text.
2. Invalid source fixtures for blank URL/name, empty arrays, null members, malformed nested values, and a domain-policy rejection distinguished from JSON validation.
3. A full backup ZIP with `bookshelf.json`, `bookSource.json`, `bookGroup.json`, and `config.xml`; cover absent optional files and reject path traversal entries.
4. Network and local books preserving custom metadata, order, opaque variables, and nonzero progress.
5. `file://` and `content://` cases proving no Android path/URI appears in the Liber contract and unresolved local entries retain metadata/progress.
6. All 64 custom group bits, explicitly including `Long.MIN_VALUE`, plus synthetic negative group IDs that must not become custom groups.
7. Restore-conflict fixtures covering same `bookUrl`, and different `bookUrl` with the same `(name, author)`.
8. Repeated imports, older/equal/newer progress, source replacement approval, group union, and non-destructive metadata merge.
9. Loss reporting for cookies, caches, chapters, downloaded content, and local file bytes; the importer must not silently imply preservation.
10. `BookProgress` fixtures with missing fields, nullable title, 64-bit millisecond time, and deterministic round trips.
11. A legacy UI `books.json` fixture proving it is detected as lossy and is never accepted as a full migration package.
12. Deterministic canonical output for the frozen-baseline fixture, including group names and local correlation hashes.

## Verification

### Parent Revalidation

- **CONFIRMED** — `git rev-parse HEAD` in the Legado reference repository returned `14dd24945b2914ce2708b8abaa4ee67ceef892af`.
- **CONFIRMED** — `git status --short` in the reference repository reported only the pre-existing untracked `.codegraph`; no reference source file was modified.
- **CONFIRMED** — The parent independently reread the cited source paths and recomputed every citation line used in this corrected report.

### Independent Review

A fresh read-only reviewer returned **PASS WITH CORRECTIONS** and no critical findings. Corrections incorporated here:

- Include `Long.MIN_VALUE` as the 64th custom group bit.
- Document the `(name, author)` unique-index replacement path.
- Separate UI and API Book Source validation requirements.
- Mark incoming `BookProgress` requiredness unconfirmed.
- Mark Liber fixtures and tests as inference.
- Distinguish domain-policy rejection from JSON parsing.
- Correct `customOrder` preservation wording.
- Regenerate source line citations against the frozen checkout.

## Residual Risks

- The full backup has no declared compatibility version; any other Legado snapshot needs its own adapter verification.
- Normal backup cannot carry local book bytes, credentials, cookies, chapters, or cache state.
- The recommended Liber envelope is a planning decision and still requires schema/spec finalization before implementation.
