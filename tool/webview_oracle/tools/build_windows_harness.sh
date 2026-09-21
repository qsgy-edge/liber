#!/usr/bin/env bash
# Builds the one destination harness binary the Windows sweep reuses, after
# verifying the sources it is built from.
#
# The adapter the fixtures drive is the product's own
# (`lib/source/book_source_webview_adapter.dart` plus its
# `inappwebview_book_source_adapter.dart` engine binding), reached through a path
# dependency, so the binary is a function of the harness sources *and* of those
# two product files. Both sets are hashed here, and a later edit is what the
# manifest writer refuses to describe as this sweep's evidence.
#
# The build runs in the committed tree. The archived prototype built from a
# short-path copy because its committed path plus the CMake plugin symlinks
# exceeded MAX_PATH; this repository's committed path is short enough, so the
# copy is gone rather than kept as ceremony. See `NOTES.md`.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(cygpath -m "$root" 2>/dev/null || printf '%s' "$root")"
adapter="$root/adapter"
product="$(cygpath -m "$root/../..")"

sha() { sha256sum "$1" | cut -d' ' -f1; }

for file in \
  "$adapter/lib/product_webview.dart" \
  "$adapter/lib/fixture_runner.dart" \
  "$adapter/lib/fixtures_concurrency.dart" \
  "$adapter/lib/fixtures_error_paths.dart" \
  "$adapter/integration_test/destination_test.dart" \
  "$adapter/test_driver/integration_test.dart" \
  "$product/lib/source/book_source_webview_adapter.dart" \
  "$product/lib/source/inappwebview_book_source_adapter.dart"; do
  printf 'SOURCE_SHA256 %s %s\n' "$(sha "$file")" "${file#"$product"/}"
done

bash "$adapter/tool/sync_fixtures.sh"
(cd "$adapter" &&
  fvm flutter build windows --debug --no-pub \
    --target=integration_test/destination_test.dart 2>&1 |
  tr -d '\r' | grep -viE 'warning' | tail -2)
sha "$adapter/build/windows/x64/runner/Debug/ticket13_adapter.exe"
