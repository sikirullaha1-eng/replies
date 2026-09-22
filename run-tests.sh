#!/bin/bash
# Runs one suite of tests. Usage: ./run-tests.sh store|analysis|intelligence
set -e
cd "$(dirname "$0")"

SUITE="${1:-store}"
case "$SUITE" in
  store)        SRC="Sources/Store" ; FILE="Tests/StoreTests.swift" ;;
  analysis)     SRC="Sources/Store Sources/Analysis" ; FILE="Tests/AnalysisTests.swift" ;;
  intelligence) SRC="Sources/Store Sources/Analysis Sources/Intelligence" ; FILE="Tests/IntelligenceTests.swift" ;;
  *) echo "Unknown suite: $SUITE  (store|analysis|intelligence)"; exit 2 ;;
esac

if [ ! -f "$FILE" ]; then echo "No tests yet for $SUITE ($FILE)"; exit 2; fi

# shellcheck disable=SC2086
FILES=$(find $SRC -name '*.swift' | sort)
OUT="/tmp/replies-tests-$SUITE"

# shellcheck disable=SC2086
swiftc -parse-as-library $FILES "$FILE" -o "$OUT"
"$OUT"
