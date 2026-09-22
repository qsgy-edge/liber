#!/usr/bin/env bash
# The JSONPath probe of ticket #44 (see README.md): fetch the pinned jars, check
# them against jars.sha256, compile the probe against the real json-path 2.9.0 and
# write transcript.txt.
#
#   bash tool/jsonpath_probe/run.sh
#
# Requires curl, sha256sum, tr and a JDK 8+ (javac/java on PATH). The record it
# writes is LF on every platform, so a run leaves a Linux and a Windows checkout
# byte for byte identical.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
base=https://repo1.maven.org/maven2

jars=(
  "com/jayway/jsonpath/json-path/2.9.0/json-path-2.9.0.jar"
  "net/minidev/json-smart/2.5.0/json-smart-2.5.0.jar"
  "net/minidev/accessors-smart/2.5.0/accessors-smart-2.5.0.jar"
  "org/slf4j/slf4j-api/2.0.11/slf4j-api-2.0.11.jar"
  "org/ow2/asm/asm/9.6/asm-9.6.jar"
)

mkdir -p "$here/jars" "$here/out"
cd "$here"
for path in "${jars[@]}"; do
  name="${path##*/}"
  if [ ! -f "$here/jars/$name" ]; then
    echo "fetching $name"
    curl -sS -o "$here/jars/$name" "$base/$path"
  fi
done

(cd "$here/jars" && sha256sum -c ../jars.sha256)

# The classpath separator follows the JVM, which is the platform one.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) separator=';' ;;
  *) separator=':' ;;
esac

javac -cp "jars/*" -d out JsonPathProbe.java
# stderr carries SLF4J's "no providers" notice, which is not part of the record,
# and `tr` keeps the record LF on Windows too, where the JVM would write CRLF.
java -cp "out${separator}jars/*" JsonPathProbe 2>/dev/null | tr -d '\r' > transcript.txt
echo "wrote $here/transcript.txt"