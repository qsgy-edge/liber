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
- **A Rust text engine** (`packages/fjs/liber_text`, same native library as the
  runtime and the HTML adapter) for local files: encoding detection (GBK, GB18030,
  Big5 — the encodings `dart:convert` cannot read), one-pass indexing into sparse
  byte ↔ code-unit anchors and chapter boundaries, bounded window reads, and the
  reader's `t2s`/`s2t` conversion, which the Book Source host surface's
  `java.t2s`/`java.s2t` share. Measured on a 500 MB TXT: 609 ms and 5.7 MB peak
  RSS, against 11.6 s for a pure-Dart pass and 2.8 s / 817 MB for the whole-file
  read it replaces. See [`tool/text_engine_prototype/`](tool/text_engine_prototype/README.md)
  and [ADR 0010](docs/adr/0010-convert-chinese-with-hanlp-tables.md).
- **Automated gates** for that slice, including frozen differentials against an
  Android-generated golden (see below).

Not covered yet, and deliberately visible rather than implied:

- Only Windows integrates the runtime and the application. Android, iOS, macOS,
  and Linux compile the native library and run the shared runtime gates in CI,
  but their limits and WebView rows are `not-run`.
- The frozen four-stage differential corpus, the security boundary for
  untrusted sources, and the request/JS capabilities listed in
  [`docs/compatibility/book-source-capability-matrix.md`](docs/compatibility/book-source-capability-matrix.md)
  are still open. A Book Source is only compatible when every stage it reaches
  passes the differential contract on that platform.

## Layout

| Path | Contents |
|---|---|
| `lib/` | Flutter application, domain contracts, local library, migration importer, and the source pipelines |
| `packages/fjs/` | Vendored `fjs` package, FRB glue, and the `libfjs` Rust crate with the shared runtime (ADR 0009) |
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
cargo test --locked --manifest-path packages/fjs/liber_text/Cargo.toml
```

`pubspec.lock` records the host each package came from. This project resolves
against the mirror `https://pub.flutter-io.cn`, and CI sets the same
`PUB_HOSTED_URL`. A `flutter pub get` in a shell without that variable rewrites
all 105 `url:` lines to another host, and the enforced get above then fails;
export it when it is missing.

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
- The delivery phases and the claim ladder live in
  [`docs/compatibility/delivery-phases.md`](docs/compatibility/delivery-phases.md):
  a phase's claim needs its own gate green and every earlier claim still holding,
  and every claim is per platform (ADR 0002/0009).
- The delivery notes in [`book_sources/README.md`](book_sources/README.md)
  record what each Windows run measured, and which rows were never executed.

### Driving the UI

The Windows app is reviewed by driving it, not by clicking on the machine's own
mouse and keyboard. Anything a widget test can express belongs in `test/`
(`flutter test test` taps the pages in-process, with no window and no input
devices); what is left over is driven on the real app. `tool/driver_main.dart`
is a debug-only entrypoint that enables the Flutter Driver extension before the
app runs, and `--dart-define=LIBER_WORKSPACE_ROOT=<path>` opens that
installation directory instead of `%APPDATA%\Liber`:

```bash
flutter run -d windows --target tool/driver_main.dart \
  --dart-define=LIBER_WORKSPACE_ROOT=C:/path/to/scratch
```

Point the scratch directory at a copy of the installation being reviewed when
the review needs real data. Nothing in a driven run reads or writes the
operator's own library, and no input reaches the operator's devices.

With Dart MCP the sequence is `launch_app` (with `target:
tool/driver_main.dart` and the define) → `dtd connect` → `flutter_driver_command
get_health`, which must answer `method: ext.flutter.driver` with `status: ok`
before any input, then `flutter_driver_command tap` with a finder: `ByText`,
`ByValueKey`, `ByType`, or `ByType` + `Descendant` when only a label repeats.
`enter_text` needs a field that accepts input, and a page is read back through
the accessibility tree or a screenshot rather than through the driver.

Four things the driver cannot reach, and who does them instead: a Windows
folder dialog (`选择根目录` and the trial page's `选择书源 JSON` open one, so the
operator picks the file, or the store's `sources` row is seeded and the page is
entered with that source selected), a caret position (`保存位置` writes the
cursor's offset, which the driver does not move), and any judgement about how
the screen looks.

Three driver mechanics cost a session before they are known. A `tap` matches
with `hitTestable()`, so a target below the fold is never tappable and the
command hangs until its timeout — `scrollIntoView` it first, and the same tap
returns at once. A wait whose target is *absent* needs a new frame
(`_waitUntilFrame` re-arms through `addPostFrameCallback`), and an idle app
produces none, so it too hangs; a dialog nobody has answered is exactly that
case, and the app's own log records
`FlutterDriverExtension: Timeout while executing …`. Waits whose target is
already present return immediately, so probe with something you know exists.
And a `PrintWindow` capture can come back stale or partially composited — two
captures taken minutes apart can carry identical bytes — so read layout from
the widget inspector (`widget_inspector` → `get_widget_tree`, which needs no
frame) or from a widget test, and treat a capture as evidence of content only.

A driven review is recorded like any other executed evidence: the exact strings
and rows the app showed, the database rows behind them, and the commands that
produced them.

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
