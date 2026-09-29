#!/usr/bin/env bash
set -euo pipefail

readonly FLUTTER_VERSION='3.44.6'
readonly RUST_VERSION='1.97.0'
readonly FLUTTER_ROOT="${HOME}/.local/share/liber/flutter-${FLUTTER_VERSION}"

if [[ "$(uname -s)" != 'Linux' ]]; then
  echo 'This bootstrap supports Linux only.' >&2
  exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
  echo 'sudo is required to install the Linux build packages.' >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo 'git is required to fetch the pinned Flutter SDK.' >&2
  exit 1
fi
if ! command -v rustup >/dev/null 2>&1; then
  echo 'Install rustup using its official instructions, then rerun this script.' >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y \
  clang \
  libclang-dev \
  cmake \
  ninja-build \
  pkg-config \
  libssl-dev \
  libgtk-3-dev \
  liblzma-dev \
  libstdc++-12-dev

if [[ ! -e "$FLUTTER_ROOT" ]]; then
  mkdir -p "$(dirname "$FLUTTER_ROOT")"
  git clone --depth 1 --branch "$FLUTTER_VERSION" \
    https://github.com/flutter/flutter.git "$FLUTTER_ROOT"
else
  echo "Refusing to modify existing Flutter path: $FLUTTER_ROOT" >&2
  exit 1
fi

rustup toolchain install "$RUST_VERSION" --profile minimal
rustup default "$RUST_VERSION"
export PATH="$FLUTTER_ROOT/bin:$HOME/.cargo/bin:$PATH"

printf '\nInstalled toolchain versions:\n'
flutter --version
rustc --version
cargo --version
printf '\nLinux package versions:\n'
for package in clang libclang-dev cmake ninja-build pkg-config libssl-dev \
  libgtk-3-dev liblzma-dev libstdc++-12-dev; do
  dpkg-query --show --showformat='${Package} ${Version}\n' "$package"
done
