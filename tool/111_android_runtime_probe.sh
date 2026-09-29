#!/usr/bin/env bash
set -euo pipefail

# This file is invoked as one command by android-emulator-runner: the action
# otherwise splits multiline `script` inputs into independent commands.
toolchain="$ANDROID_HOME/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64"
test -d "$toolchain"
export CC_x86_64_linux_android="$toolchain/bin/x86_64-linux-android26-clang"
export AR_x86_64_linux_android="$toolchain/bin/llvm-ar"
export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$toolchain/bin/x86_64-linux-android26-clang"

abi="$(adb -s emulator-5554 shell getprop ro.product.cpu.abi | tr -d '\r')"
echo "ANDROID_EMULATOR_ABI=$abi" | tee android-abi.txt
test "$abi" = x86_64
flutter devices --machine | tee flutter-devices.json
python3 - <<'PY'
import json, sys
devices = json.load(open('flutter-devices.json'))
if not any(d.get('id') == 'emulator-5554' and d.get('targetPlatform', '').startswith('android') for d in devices):
    sys.exit('ANDROID_DEVICE_NOT_RUN: Flutter cannot select the booted emulator')
print('FLUTTER_ANDROID_EMULATOR_AVAILABLE=emulator-5554')
PY

flutter test integration_test/heap_limit_mobile_probe_test.dart \
  -d emulator-5554 --no-pub --reporter expanded 2>&1 | tee android-runtime-test.log
grep -q '^FJS_MOBILE_SINGLE_REQUEST passed=200 lost=0 usable=200$' android-runtime-test.log
grep -q '^FJS_MOBILE_ACCUMULATING passed=1 usable=1$' android-runtime-test.log
grep -q '^FJS_MOBILE_POINTER_WIDTH bits=64 not-applicable$' android-runtime-test.log
grep -q 'All tests passed!' android-runtime-test.log
