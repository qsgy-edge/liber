#!/usr/bin/env bash
# Regenerate tool/jsonpath_oracle/evidence/jvm-host/golden.json by compiling the
# frozen Legado revision's AnalyzeByJSonPath.kt and RuleAnalyzer.kt and running
# the harness over fixtures.json. See README.md for the provenance this records.
#
# The Kotlin compiler, kotlin-stdlib and kotlin-reflect come from the local
# Gradle cache, because no kotlinc is on PATH on the operator's machine. The
# json-path 2.9.0 jars are the ones tool/jsonpath_probe/ pins by sha256 and
# fetches from Maven Central; this script reuses that directory and verifies the
# same hash list, so both hosts run the same bytes.
#
# Override with env vars:
#   LIBER_LEGADO       frozen Legado checkout (default D:/GithubRepositories/Android/legado)
#   GRADLE_CACHE       Gradle module cache (default ~/.gradle/caches/modules-2/files-2.1)
#   JSONPATH_JARS      a directory holding the five json-path jars
#   KOTLIN_COMPILER / KOTLIN_STDLIB / KOTLIN_REFLECT
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
frozen="${LIBER_LEGADO:-D:/GithubRepositories/Android/legado}"
gradle_cache="${GRADLE_CACHE:-$HOME/.gradle/caches/modules-2/files-2.1}"
jars="${JSONPATH_JARS:-$here/../jsonpath_probe/jars}"
pins="$here/../jsonpath_probe/jars.sha256"
base=https://repo1.maven.org/maven2

jsonpath_jars=(
  "com/jayway/jsonpath/json-path/2.9.0/json-path-2.9.0.jar"
  "net/minidev/json-smart/2.5.0/json-smart-2.5.0.jar"
  "net/minidev/accessors-smart/2.5.0/accessors-smart-2.5.0.jar"
  "org/slf4j/slf4j-api/2.0.11/slf4j-api-2.0.11.jar"
  "org/ow2/asm/asm/9.6/asm-9.6.jar"
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
gson="$(require_jar com.google.code.gson/gson 'gson-*.jar')"
# The frozen file carries androidx.annotation.Keep. The real annotation jar from
# the Gradle cache stands in for the Android build's classpath entry: it is an
# annotation, so this changes nothing the harness executes.
keep_jar="$(require_jar androidx.annotation/annotation-jvm 'annotation-jvm-*.jar')"

mkdir -p "$jars"
for path in "${jsonpath_jars[@]}"; do
  name="${path##*/}"
  [ -f "$jars/$name" ] || curl -sS -o "$jars/$name" "$base/$path"
done
(cd "$jars" && sha256sum -c "$pins" >/dev/null) || {
  echo "run_golden.sh: $jars does not match $pins" >&2
  exit 1
}

classpath="$stdlib;$gson;$keep_jar"
for path in "${jsonpath_jars[@]}"; do
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

out="$(mktemp -d)"
java -Dfile.encoding=UTF-8 \
  -cp "$(jar "$kc");$(jar "$stdlib");$(jar "$reflect");$(jar "$coroutines");$(jar "$trove");$(jar "$annotations")" \
  org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-reflect -no-stdlib -jvm-target 1.8 -cp "$cp_win" -d "$(jar "$out")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/model/analyzeRule/RuleAnalyzer.kt")" \
  "$(jar "$frozen/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSonPath.kt")" \
  "$(jar "$here/FrozenDebugStub.kt")" \
  "$(jar "$here/JsonPathOracle.kt")" >/dev/null

# stderr carries SLF4J's "no providers" notice, which is not part of the record.
java -Dfile.encoding=UTF-8 -cp "$(jar "$out");$cp_win" \
  tool.jsonpath.JsonPathOracleKt \
  "$(jar "$here/fixtures.json")" \
  "$(jar "$here/evidence/jvm-host/golden.json")" 2>/dev/null

echo "kotlin-compiler-embeddable $(basename "$kc" .jar)" >&2
echo "kotlin-stdlib $(basename "$stdlib" .jar)" >&2
echo "gson $(basename "$gson" .jar)" >&2
echo "json-path $(basename "${jsonpath_jars[0]}" .jar)" >&2
echo "androidx.annotation $(basename "$keep_jar" .jar)" >&2
