#!/usr/bin/env bash
# Regenerate tool/re_segment_oracle/evidence/jvm-host/golden.json by compiling
# the frozen Legado revision's ContentHelp.kt and running the harness over
# fixtures.json. See README.md for the provenance this records.
#
# It resolves the Kotlin compiler and Gson from the local Gradle cache, because
# no kotlinc is on PATH on the operator's machine. Override with env vars:
#   LIBER_LEGADO       frozen Legado checkout (default D:/GithubRepositories/Android/legado)
#   KOTLIN_COMPILER    kotlin-compiler-embeddable jar
#   KOTLIN_STDLIB      kotlin-stdlib jar
#   GSON_JAR           gson jar
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
frozen="${LIBER_LEGADO:-D:/GithubRepositories/Android/legado}/app/src/main/java/io/legado/app/help/book/ContentHelp.kt"
gradle_cache="${GRADLE_CACHE:-$HOME/.gradle/caches/modules-2/files-2.1}"

find_jar() { find "$gradle_cache/$1" -name "$2" | sort -V | tail -1; }

kc="${KOTLIN_COMPILER:-$(find_jar org.jetbrains.kotlin/kotlin-compiler-embeddable 'kotlin-compiler-embeddable-2.1.0.jar')}"
stdlib="${KOTLIN_STDLIB:-$(find_jar org.jetbrains.kotlin/kotlin-stdlib 'kotlin-stdlib-2.1.0.jar')}"
coroutines="$(find_jar org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm 'kotlinx-coroutines-core-jvm-1.10.1.jar')"
trove="$(find_jar org.jetbrains.intellij.deps/trove4j 'trove4j-1.0.20200330.jar')"
annotations="$(find_jar org.jetbrains/annotations 'annotations-23.0.0.jar')"
gson="${GSON_JAR:-$(find_jar com.google.code.gson/gson 'gson-2.12.1.jar')}"

jar() { cygpath -w "$1"; }
out="$(mktemp -d)"

java -Dfile.encoding=UTF-8 -cp "$(jar "$kc");$(jar "$stdlib");$(jar "$coroutines");$(jar "$trove");$(jar "$annotations")" \
  org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-reflect -no-stdlib -cp "$(jar "$stdlib");$(jar "$gson")" -d "$(jar "$out")" \
  "$(jar "$frozen")" "$(jar "$here/ReSegmentOracle.kt")" >/dev/null

java -Dfile.encoding=UTF-8 -cp "$(jar "$out");$(jar "$stdlib");$(jar "$gson")" \
  tool.resegment.ReSegmentOracleKt \
  "$(jar "$here/fixtures.json")" \
  "$(jar "$here/evidence/jvm-host/golden.json")"
