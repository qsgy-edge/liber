#!/usr/bin/env bash
# Copies the committed fixtures into the Flutter asset tree so the device reads
# the exact committed bytes. Run before every build; the copy is gitignored so
# the committed fixtures stay the single source of truth.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$here/assets/fixtures"
rm -f "$here/assets/fixtures"/WV-*.json
cp "$here/../fixtures"/WV-*.json "$here/assets/fixtures/"
