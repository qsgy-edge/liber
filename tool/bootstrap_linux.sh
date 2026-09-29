#!/usr/bin/env bash
set -euo pipefail

readonly FLUTTER_VERSION='3.44.6'
readonly RUST_VERSION='1.97.0'
readonly FLUTTER_ROOT="${HOME}/.local/share/liber/flutter-${FLUTTER_VERSION}"
readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != 'Linux' ]]; then
  echo 'This bootstrap supports Linux only.' >&2
  exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
  echo 'sudo is required to install the Linux build packages.' >&2
  exit 1
fi
sudo apt-get update
sudo apt-get install -y \
  curl \
  git \
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

if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
    sh -s -- -y --no-modify-path --profile minimal --default-toolchain none
fi
export PATH="$FLUTTER_ROOT/bin:$HOME/.cargo/bin:$PATH"
rustup toolchain install "$RUST_VERSION" --profile minimal
cd "$REPO_ROOT"

printf '\nInstalled toolchain versions:\n'
flutter --version
rustc --version
cargo --version
printf '\nLinux package versions:\n'
for package in curl git clang libclang-dev cmake ninja-build pkg-config libssl-dev \
  libgtk-3-dev liblzma-dev libstdc++-12-dev; do
  dpkg-query --show --showformat='${Package} ${Version}\n' "$package"
done

printf '\nTo enable Flutter, Dart, and Rust in the current shell, run:\n  export PATH="%s/bin:%s/.cargo/bin:$PATH"\n\n' \
  "$FLUTTER_ROOT" "$HOME"
