# Liber

Liber is a Flutter reader for books that come from two sources: remote services
described by user-imported **Book Sources**, and local TXT or Markdown files the
user picks from their own folders. Its goal is to reproduce the *observable*
Book Source behavior of a frozen Legado baseline on Windows, Android, iOS,
macOS, and Linux — not to clone Legado's interface.

The migration route, its open decisions, and the frontier are tracked as GitHub
issues: the **map** is the issue labelled `wayfinder:map`, and its child issues
are the tickets. Terminology is defined in [`CONTEXT.md`](CONTEXT.md); the
compatibility contracts are in [`docs/compatibility/`](docs/compatibility/).

## Status

Early and Windows-first. What runs on `master` today:

- **Windows application** (`flutter run -d windows`) with four entries: 书源试读
  (import a Book Source JSON and read search → details → chapters → content),
  在线书架 (shelf with per-book progress and cached tables of contents),
  本地书库 (pick a folder, add TXT/Markdown books, read them), and a Legado
  backup importer with a loss report.
- **Source execution** for the bounded slice that the sample sources need:
  legacy and `@CSS:` selectors with `@` chains, index/exclusion/slice syntax and
  `##` replacement; a `$.`-style JSON adapter; `,{...}` request options
  (`method`, `headers`, `body`, `js`, `retry`); static, `@js:` and `<js>` header
  rules; four stages with directory and content page chaining; session cookies.
- **A synchronous JavaScript runtime** built on a vendored `fjs`/QuickJS native
  library (`packages/fjs`), with a cancellable host bridge, byte and heap caps,
  and an allowlisted host surface. See
  [`packages/fjs/LIBER.md`](packages/fjs/LIBER.md).
- **Automated gates** for that slice, including frozen differentials against an
  Android-generated golden (see below).

Not covered yet, and deliberately visible rather than implied:

- Only Windows integrates the runtime and the application. Android, iOS, macOS,
  and Linux currently compile the native library; their runtime rows are
  `not-run`.
- The frozen four-stage differential corpus, the security boundary for
  untrusted sources, and the request/JS capabilities listed in
  [`docs/compatibility/book-source-capability-matrix.md`](docs/compatibility/book-source-capability-matrix.md)
  are still open. A Book Source is only compatible when every stage it reaches
  passes the differential contract on that platform.

## Layout

| Path | Contents |
|---|---|
| `lib/` | Flutter application, domain contracts, local library, migration importer, and the source pipelines |
| `packages/fjs/` | Vendored `fjs` package, FRB glue, and the `libfjs` Rust crate with the Windows fiber scheduler |
| `tool/` | Gate runners, oracle comparison scripts, frozen oracle evidence, and live-source helpers |
| `test/`, `integration_test/` | Dart and Flutter tests |
| `docs/compatibility/` | The compatibility baseline, the differential contract, the migration contract, the capability inventory, and the runtime-component survey |
| `docs/user-data-contract.md` | The settled user-data contract: storage layout, identity, groups, progress, sources, and replace rules |
| `docs/agents/`, `docs/adr/` | Agent configuration for this repo and the architecture decision records |
| `book_sources/` | Delivery notes for the Windows slice and sample source definitions |

The private `liber-archive` repository keeps the earlier history of this project,
the retired prototype harnesses (including the WebView contract lane whose
executed evidence is not published here), and the CI artifacts older notes cite.

## Build and run

Requirements: Flutter 3.44.6 (Dart SDK `^3.12.2`), a Rust toolchain
(`1.97.0` in CI) for the native library, Python 3 for the gate runner, and the
WebView2 Runtime on Windows.

```bash
flutter pub get --enforce-lockfile
flutter run -d windows          # the application
flutter test test               # shared tests
dart analyze lib test integration_test tool
```

The desktop gates run against the built native library:

```bash
flutter build windows --debug --no-pub          # writes build/windows/x64/runner/Debug/fjs.dll
python tool/ci_runtime.py windows x86_64-pc-windows-msvc
```

`tool/ci_runtime.py` is the same runner CI uses. It writes per-command logs and
a manifest with the library hash, the script hashes, and every exit code, and it
fails a command whose log contains the Dart VM crash marker even when the
process exited 0.

To measure a set of real sources against the current implementation without
logging their headers or bodies:

```bash
dart run tool/source_triage.dart <path-to-fjs.dll> <exported-sources.json>
```

## Verification and evidence

- Goldens for the source runtime are produced by executing the frozen Legado
  baseline, never written by hand; the comparison scripts and the committed
  goldens live in `tool/`. The harnesses for those runs are in this repository;
  the WebView contract harness is in `liber-archive` because it links against
  the frozen application's classes.
- Aggregate compatibility claims must keep `not-run` rows, coverage gaps, and
  policy rejections visible. A green workflow is not a compatibility verdict.
- The delivery notes in [`book_sources/README.md`](book_sources/README.md)
  record what each Windows run measured, and which rows were never executed.

## Compatibility baseline

Book Source compatibility is defined against a local Legado snapshot at commit
`14dd24945b2914ce2708b8abaa4ee67ceef892af`. Upstream `main` was replaced by a
notice-only history and is not a baseline; see
[`docs/compatibility/legado-compatibility-baseline.md`](docs/compatibility/legado-compatibility-baseline.md).

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT) at your option; see
[`LICENSE`](LICENSE), and [`NOTICE`](NOTICE) for third-party components. The
vendored `packages/fjs` keeps its own MIT license.
