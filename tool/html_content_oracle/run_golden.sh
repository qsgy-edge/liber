#!/usr/bin/env bash
# Regenerate tool/html_content_oracle/evidence/jvm-host/{golden,manifest}.json by
# compiling the frozen Legado revision's HtmlFormatter.kt and AppPattern.kt and
# running the harness over fixtures.json. See README.md for the provenance this
# records.
#
# The Kotlin compiler, kotlin-stdlib, kotlin-reflect and Gson come from the local
# Gradle cache, because no kotlinc is on PATH on the operator's machine. The two
# Apache Commons jars are the frozen revision's own `commons-text` 1.13.0 and the
# `commons-lang3` it needs: the frozen `BookContent` unescapes through
# `StringEscapeUtils.unescapeHtml4`, and a hand-written entity table is not the
# frozen behaviour. They are fetched from Maven Central once and verified against
# `jars.sha256`.
#
# No Android stub jar is on any classpath: HtmlFormatter.kt and AppPattern.kt
# name no Android type. The Android-bound statements reached through the
# formatter are transcribed into FrozenContentStubs.kt / FrozenAnalyzeUrlStub.kt
# and verified against the frozen files by the harness.
#
# Override with env vars:
#   LIBER_LEGADO       frozen Legado checkout (default D:/GithubRepositories/Android/legado)
#   GRADLE_CACHE       Gradle module cache (default ~/.gradle/caches/modules-2/files-2.1)
#   COMMONS_JARS       a directory holding the two Apache Commons jars
#   KOTLIN_COMPILER / KOTLIN_STDLIB / KOTLIN_REFLECT / GSON_JAR
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

commons_jars=(
  "org/apache/commons/commons-text/1.13.0/commons-text-1.13.0.jar"
  "org/apache/commons/commons-lang3/3.17.0/commons-lang3-3.17.0.jar"
)

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
for path in "${commons_jars[@]}"; do
  name="${path##*/}"
  [ -f "$jars/$name" ] || curl -sS -o "$jars/$name" "$base/$path"
done
(cd "$jars" && sha256sum -c "$pins" >/dev/null) || {
  echo "run_golden.sh: $jars does not match $pins" >&2
  exit 1
}

classpath="$stdlib;$gson"
for path in "${commons_jars[@]}"; do
  classpath="$classpath;$jars/${path##*/}"
done

jar() { cygpath -w "$1"; }
windows_classpath() {
  local joined='' entry
  local IFS=';'
  for entry in $classpath; do
    joined="${joined:+$joined;}$(cygpath -w "$entry")"
  done
  printf '%s' "$joined"
}
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
