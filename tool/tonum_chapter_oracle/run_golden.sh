#!/usr/bin/env bash
# Regenerate tool/tonum_chapter_oracle/evidence/jvm-host/golden.json by
# compiling the frozen Legado revision's AppPattern.kt and StringUtils.kt and
# running the harness over fixtures.json. See README.md for the provenance this
# records.
#
# The Kotlin compiler, kotlin-stdlib, kotlin-reflect and Gson come from the
# local Gradle cache, because no kotlinc is on PATH on the operator's machine.
# The Android SDK's stub android.jar is on the *compile* classpath only: the
# frozen StringUtils.kt imports android.text.TextUtils and android.util.Base64
# for functions this corpus never calls, and the stub jar makes such a call fail
# loudly at run time instead of being silently satisfied by a hand-written shim.
#
# Override with env vars:
#   LIBER_LEGADO       frozen Legado checkout (default D:/GithubRepositories/Android/legado)
#   GRADLE_CACHE       Gradle module cache (default ~/.gradle/caches/modules-2/files-2.1)
#   ANDROID_JAR        the SDK's compile-only stub jar
#   KOTLIN_COMPILER / KOTLIN_STDLIB / KOTLIN_REFLECT / GSON_JAR
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
frozen="${LIBER_LEGADO:-D:/GithubRepositories/Android/legado}"
gradle_cache="${GRADLE_CACHE:-$HOME/.gradle/caches/modules-2/files-2.1}"

find_jar() { find "$gradle_cache/$1" -name "$2" | sort -V | tail -1; }
require_jar() {
  local path
  path="$(find_jar "$1" "$2")"
  if [ -z "$path" ]; then
    echo "run_golden.sh: no $2 in $gradle_cache/$1 (set the matching env var)" >&2
    exit 1
  fi
  printf '%s' "$path"
}

kc="${KOTLIN_COMPILER:-$(require_jar org.jetbrains.kotlin/kotlin-compiler-embeddable 'kotlin-compiler-embeddable-2*.jar')}"
stdlib="${KOTLIN_STDLIB:-$(require_jar org.jetbrains.kotlin/kotlin-stdlib 'kotlin-stdlib-2*.jar')}"
reflect="${KOTLIN_REFLECT:-$(require_jar org.jetbrains.kotlin/kotlin-reflect 'kotlin-reflect-2*.jar')}"
coroutines="$(require_jar org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm 'kotlinx-coroutines-core-jvm-*.jar')"
trove="$(require_jar org.jetbrains.intellij.deps/trove4j 'trove4j-*.jar')"
annotations="$(require_jar org.jetbrains/annotations 'annotations-*.jar')"
gson="${GSON_JAR:-$(require_jar com.google.code.gson/gson 'gson-*.jar')}"

# The SDK's stub jar, found the same way the frozen project finds its SDK.
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$sdk_root" ]; then
  for properties in "$frozen/local.properties" "$here/../../android/local.properties"; do
    [ -f "$properties" ] || continue
    sdk_root="$(sed -n 's/^sdk\.dir=//p' "$properties" | tr -d '\r' | tr '\\' '/')"
    [ -n "$sdk_root" ] && break
  done
fi
# compile_sdk_version = 35 in the frozen build.gradle; fall back to the newest
# installed platform when 35 is absent. The jar is never on the run classpath.
android_jar="${ANDROID_JAR:-}"
if [ -z "$android_jar" ] && [ -n "$sdk_root" ] && [ -d "$sdk_root/platforms/android-35" ]; then
  android_jar="$sdk_root/platforms/android-35/android.jar"
fi
if [ -z "$android_jar" ] && [ -n "$sdk_root" ] && [ -d "$sdk_root/platforms" ]; then
  android_jar="$(ls -d "$sdk_root"/platforms/android-[0-9]* 2>/dev/null | sort -V | tail -1)/android.jar"
fi
if [ -z "$android_jar" ] || [ ! -f "$android_jar" ]; then
  echo "run_golden.sh: no Android SDK stub jar found (set ANDROID_JAR)" >&2
  exit 1
fi

jar() { cygpath -w "$1"; }
out="$(mktemp -d)"

java -Dfile.encoding=UTF-8 \
  -cp "$(jar "$kc");$(jar "$stdlib");$(jar "$reflect");$(jar "$coroutines");$(jar "$trove");$(jar "$annotations")" \
  org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-reflect -no-stdlib -jvm-target 1.8 \
  -cp "$(jar "$stdlib");$(jar "$gson");$(jar "$android_jar")" -d "$(jar "$out")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/constant/AppPattern.kt")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/utils/StringUtils.kt")" \
  "$(jar "$here/FrozenDebugStub.kt")" \
  "$(jar "$here/ToNumChapterOracle.kt")" >/dev/null

java -Dfile.encoding=UTF-8 -cp "$(jar "$out");$(jar "$stdlib");$(jar "$gson")" \
  tool.tonum.ToNumChapterOracleKt \
  "$(jar "$here/fixtures.json")" \
  "$(jar "$here/evidence/jvm-host/golden.json")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/help/JsExtensions.kt")"

echo "kotlin-compiler-embeddable $(basename "$kc" .jar)" >&2
echo "kotlin-stdlib $(basename "$stdlib" .jar)" >&2
echo "gson $(basename "$gson" .jar)" >&2
echo "android stub jar $(cygpath -m "$android_jar")" >&2
