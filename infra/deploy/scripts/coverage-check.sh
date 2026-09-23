#!/usr/bin/env bash
# CI coverage gate: fails if total statement coverage drops below threshold.
# Current floor 70% (2026-08-19): engine 87.9%, api 86.8%, overall 88.1%.
set -euo pipefail

THRESHOLD="${COVERAGE_THRESHOLD:-70.0}"
WORKDIR="${1:-.}"
TMP_COVER="$(mktemp /tmp/cover.XXXXXX.out)"
trap 'rm -f "$TMP_COVER"' EXIT

cd "$WORKDIR"
go test ./... -coverprofile="$TMP_COVER" >/dev/null
TOTAL=$(go tool cover -func="$TMP_COVER" | awk '/^total:/ { gsub(/%/,"",$3); print $3 }')

echo "Total test coverage: ${TOTAL}% (threshold: ${THRESHOLD}%)"
awk -v t="$TOTAL" -v th="$THRESHOLD" 'BEGIN {
    if (t + 0 < th + 0) { print "FAIL: coverage below threshold"; exit 1 }
    print "PASS: coverage gate satisfied"
}'
