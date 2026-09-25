#!/usr/bin/env bash
# Regenerate tool/html_content_oracle/evidence/jvm-host/{golden,manifest}.json by
# compiling the frozen Legado revision's HtmlFormatter.kt and AppPattern.kt and
# running the harness over fixtures.json, and
# tool/html_content_oracle/evidence/jvm-host/{replace-golden,replace-manifest}.json
# by compiling the frozen AnalyzeRule.kt, RuleDataInterface.kt, AnalyzeByRegex.kt
# and the frozen modules/rhino script engine and running the replace harness over
# replace_fixtures.json. See README.md for the provenance this records.
#
# The Kotlin compiler, kotlin-stdlib, kotlin-reflect and Gson come from the local
# Gradle cache, because no kotlinc is on PATH on the operator's machine. The two
# Apache Commons jars are the frozen revision's own `commons-text` 1.13.0 and the
# `commons-lang3` it needs: the frozen `BookContent` unescapes through
# `StringEscapeUtils.unescapeHtml4`, and a hand-written entity table is not the
# frozen behaviour. `org.mozilla:rhino:1.8.0` is the JS engine the frozen
# revision pins (`gradle/libs.versions.toml:40`), and it is the engine the
# `{{...}}` substitutions of the replace corpus are evaluated with; all three
# jars are fetched from Maven Central once and verified against `jars.sha256`.
#
# The replace step needs the Android SDK's stub `android.jar` on its compile
# classpath (the frozen `AnalyzeRule` names `android.text.TextUtils`, and the
# frozen script module reads `android.os.Build`), the `androidx.annotation` jar
# for the frozen `@Keep`, and the `okio` jar the module's class shutter names.
# Its run needs a JVM that can load Rhino 1.8.0 (class file 55), which the
# operator's Java 8 cannot: the script takes `REPLACE_JAVA`, or discovers the
# Android Studio JBR, or takes a `java` on `PATH` that reports 11+, and records
# which one it used in the manifest.
#
# No Android stub jar is on the first step's classpath: HtmlFormatter.kt and
# AppPattern.kt name no Android type. The Android-bound statements reached
# through the formatter are transcribed into FrozenContentStubs.kt /
# FrozenAnalyzeUrlStub.kt and verified against the frozen files by the harness;
# the replace step's stub surface is tool/html_content_oracle/stubs/.
#
# Override with env vars:
#   LIBER_LEGADO       frozen Legado checkout (default D:/GithubRepositories/Android/legado)
#   GRADLE_CACHE       Gradle module cache (default ~/.gradle/caches/modules-2/files-2.1)
#   COMMONS_JARS       a directory holding the three pinned jars
#   ANDROID_JAR        the SDK's compile-only stub jar
#   REPLACE_JAVA       a JVM 11+ for the replace step
#   KOTLIN_COMPILER / KOTLIN_STDLIB / KOTLIN_REFLECT / GSON_JAR
#   OKIO_JAR / ANDROIDX_ANNOTATION_JAR
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
frozen="${LIBER_LEGADO:-D:/GithubRepositories/Android/legado}"
gradle_cache="${GRADLE_CACHE:-$HOME/.gradle/caches/modules-2/files-2.1}"
jars="${COMMONS_JARS:-$here/jars}"
pins="$here/jars.sha256"
base=https://repo1.maven.org/maven2

# The frozen hashes this golden is labelled with: a dirty or different checkout
# cannot emit a golden that claims the baseline revision.
pins_frozen="$here/frozen.sha1"
if ! (cd "$frozen" && sha1sum -c "$pins_frozen" >/dev/null); then
  echo "run_golden.sh: $frozen does not match $pins_frozen" >&2
  exit 1
fi
pins_replace="$here/replace-frozen.sha1"
if ! (cd "$frozen" && sha1sum -c "$pins_replace" >/dev/null); then
  echo "run_golden.sh: $frozen does not match $pins_replace" >&2
  exit 1
fi

commons_jars=(
  "org/apache/commons/commons-text/1.13.0/commons-text-1.13.0.jar"
  "org/apache/commons/commons-lang3/3.17.0/commons-lang3-3.17.0.jar"
)
rhino_jar="org/mozilla/rhino/1.8.0/rhino-1.8.0.jar"

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

mkdir -p "$jars"
for path in "${commons_jars[@]}" "$rhino_jar"; do
  name="${path##*/}"
  [ -f "$jars/$name" ] || curl -sS -o "$jars/$name" "$base/$path"
done
(cd "$jars" && sha256sum -c "$pins" >/dev/null) || {
  echo "run_golden.sh: $jars does not match $pins" >&2
  exit 1
}

okio="${OKIO_JAR:-$(require_jar com.squareup.okio/okio-jvm 'okio-jvm-*.jar')}"
androidx_annotation="${ANDROIDX_ANNOTATION_JAR:-$(require_jar androidx.annotation/annotation-jvm 'annotation-jvm-*.jar')}"

# The SDK's stub jar, found the same way the frozen project finds its SDK.
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$sdk_root" ]; then
  for properties in "$frozen/local.properties" "$here/../../android/local.properties"; do
    [ -f "$properties" ] || continue
    sdk_root="$(sed -n 's/^sdk\.dir=//p' "$properties" | tr -d '\r' | tr '\\' '/')"
    [ -n "$sdk_root" ] && break
  done
fi
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

# Rhino 1.8.0 is class-file 55, so the replace step needs a JVM the operator's
# Java 8 is not. Prefer an explicit override, then the Android Studio JBR, then
# whatever `java` resolves to, and refuse a JVM that cannot load the jar.
java_major() {
  "$1" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1
}
replace_java=""
for candidate in "${REPLACE_JAVA:-}" \
  "${LOCALAPPDATA:-}/Programs/Android Studio/jbr/bin/java" \
  "$(command -v java || true)"; do
  [ -n "$candidate" ] || continue
  [ -x "$candidate" ] || continue
  major="$(java_major "$candidate")"
  if [ -n "$major" ] && [ "$major" -ge 11 ]; then
    replace_java="$candidate"
    break
  fi
done
if [ -z "$replace_java" ]; then
  echo "run_golden.sh: the replace step needs a JVM 11+ (the frozen revision's Rhino 1.8.0 is " \
    "class-file 55); set REPLACE_JAVA" >&2
  exit 1
fi

classpath="$stdlib;$gson"
for path in "${commons_jars[@]}"; do
  classpath="$classpath;$jars/${path##*/}"
done

jar() { cygpath -w "$1"; }
win_path() { cygpath -w "$1"; }
win_join() {
  local joined='' entry
  local IFS=';'
  for entry in $1; do
    joined="${joined:+$joined;}$(cygpath -w "$entry")"
  done
  printf '%s' "$joined"
}
windows_classpath() { win_join "$classpath"; }
cp_win="$(windows_classpath)"

here_win="$(cygpath -w "$here")"
frozen_win="$(cygpath -w "$frozen")"
out="$(mktemp -d)"
mkdir -p "$here/evidence/jvm-host"

java -Dfile.encoding=UTF-8 \
  -cp "$(jar "$kc");$(jar "$stdlib");$(jar "$reflect");$(jar "$coroutines");$(jar "$trove");$(jar "$annotations")" \
  org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-reflect -no-stdlib -jvm-target 1.8 \
  -cp "$cp_win" -d "$(jar "$out")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/utils/HtmlFormatter.kt")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/constant/AppPattern.kt")" \
  "$(jar "$here/FrozenContentStubs.kt")" \
  "$(jar "$here/FrozenAnalyzeUrlStub.kt")" \
  "$(jar "$here/HtmlContentOracle.kt")" >/dev/null

toolchain="$(mktemp)"
printf '{"kotlinCompiler":"%s","kotlinStdlib":"%s","kotlinReflect":"%s","gson":"%s","commonsText":"%s","commonsLang3":"%s","jvmTarget":"1.8"}\n' \
  "$(basename "$kc" .jar)" "$(basename "$stdlib" .jar)" "$(basename "$reflect" .jar)" \
  "$(basename "$gson" .jar)" "$(basename "${commons_jars[0]}" .jar)" \
  "$(basename "${commons_jars[1]}" .jar)" > "$toolchain"

java -Dfile.encoding=UTF-8 -cp "$(jar "$out");$cp_win" \
  tool.htmlcontent.HtmlContentOracleKt \
  "$(jar "$here/fixtures.json")" \
  "$(jar "$here/evidence/jvm-host/golden.json")" \
  "$(jar "$here/evidence/jvm-host/manifest.json")" \
  "$frozen_win" \
  "$(jar "$toolchain")"

echo "kotlin-compiler-embeddable $(basename "$kc" .jar)" >&2
echo "kotlin-stdlib $(basename "$stdlib" .jar)" >&2
echo "gson $(basename "$gson" .jar)" >&2
echo "commons-text $(basename "${commons_jars[0]}" .jar)" >&2
echo "commons-lang3 $(basename "${commons_jars[1]}" .jar)" >&2
echo "frozen root $frozen_win" >&2

# --- the replace step -------------------------------------------------------
#
# One compile unit: the frozen rule path, the frozen per-page formatter and the
# frozen script engine, plus the stub surface in stubs/.
out_replace="$(mktemp -d)"
rhino_jar_path="$jars/${rhino_jar##*/}"
replace_cp="$stdlib;$gson;$android_jar;$rhino_jar_path;$coroutines;$okio;$androidx_annotation;$jars/commons-text-1.13.0.jar;$jars/commons-lang3-3.17.0.jar"
replace_cp_win="$(win_join "$replace_cp")"

module_sources=()
while IFS= read -r file; do
  module_sources+=("$(win_path "$file")")
done < <(find "$frozen/modules/rhino/src/main/java" -name '*.kt' | sort)
stub_sources=()
while IFS= read -r file; do
  stub_sources+=("$(win_path "$file")")
done < <(find "$here/stubs" -name '*.kt' | sort)

java -Dfile.encoding=UTF-8 \
  -cp "$(jar "$kc");$(jar "$stdlib");$(jar "$reflect");$(jar "$coroutines");$(jar "$trove");$(jar "$annotations")" \
  org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-reflect -no-stdlib -jvm-target 1.8 \
  -cp "$replace_cp_win" -d "$(jar "$out_replace")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/utils/HtmlFormatter.kt")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/constant/AppPattern.kt")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByRegex.kt")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/model/analyzeRule/RuleDataInterface.kt")" \
  "${module_sources[@]}" \
  "$(jar "$here/FrozenContentStubs.kt")" \
  "$(jar "$here/HtmlContentOracle.kt")" \
  "$(jar "$here/ContentReplaceOracle.kt")" \
  "${stub_sources[@]}" >/dev/null

toolchain_replace="$(mktemp)"
printf '{"kotlinCompiler":"%s","kotlinStdlib":"%s","kotlinReflect":"%s","gson":"%s","commonsText":"%s","commonsLang3":"%s","rhino":"%s","okio":"%s","androidxAnnotation":"%s","androidStubJar":"%s","jvmTarget":"1.8","rhinoClassFileMajor":"55","runJvm":"%s"}\n' \
  "$(basename "$kc" .jar)" "$(basename "$stdlib" .jar)" "$(basename "$reflect" .jar)" \
  "$(basename "$gson" .jar)" "$(basename "${commons_jars[0]}" .jar)" \
  "$(basename "${commons_jars[1]}" .jar)" "$(basename "$rhino_jar" .jar)" \
  "$(basename "$okio" .jar)" "$(basename "$androidx_annotation" .jar)" \
  "$(cygpath -m "$android_jar")" "$("$replace_java" -version 2>&1 | head -1 | tr -d '"')" > "$toolchain_replace"

"$replace_java" -Dfile.encoding=UTF-8 -cp "$(jar "$out_replace");$replace_cp_win" \
  tool.htmlcontent.ContentReplaceOracleKt \
  "$(jar "$here/replace_fixtures.json")" \
  "$(jar "$here/evidence/jvm-host/replace-golden.json")" \
  "$(jar "$here/evidence/jvm-host/replace-manifest.json")" \
  "$frozen_win" \
  "$(jar "$toolchain_replace")"

echo "rhino $(basename "$rhino_jar" .jar)" >&2
echo "okio $(basename "$okio" .jar)" >&2
echo "android stub jar $(cygpath -m "$android_jar")" >&2
echo "replace step JVM $replace_java" >&2
