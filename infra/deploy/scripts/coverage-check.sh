#!/usr/bin/env bash
# CI coverage gate: fails if total statement coverage drops below threshold.
# Current floor 70% (2026-08-19): engine 87.9%, api 86.8%, overall 88.1%.
set -euo pipefail

THRESHOLD="${COVERAGE_THRESHOLD:-70.0}"
WORKDIR="${1:-.}"
TMP_COVER="$(mktemp /tmp/cover.XXXXXX.out)"
TMP_LOG="$(mktemp /tmp/cover-test.XXXXXX.log)"
trap 'rm -f "$TMP_COVER" "$TMP_LOG"' EXIT

cd "$WORKDIR"
# Keep the full output on disk. A plain `>/dev/null` made the gate exit 1 with
# *zero* diagnostics whenever the coverage pass itself hit a failing test
# (observed on run 36421220539) — the gate must always fail loudly.
if ! go test ./... -coverprofile="$TMP_COVER" >"$TMP_LOG" 2>&1; then
    echo "coverage pass: go test FAILED — failing tests:"
    grep -aE '^(--- FAIL|FAIL|ok +nms_engine)' "$TMP_LOG" | tail -20 || true
    echo "----- last 60 lines of the coverage pass -----"
    tail -60 "$TMP_LOG"
    exit 1
fi
TOTAL=$(go tool cover -func="$TMP_COVER" | awk '/^total:/ { gsub(/%/,"",$3); print $3 }')

echo "Total test coverage: ${TOTAL}% (threshold: ${THRESHOLD}%)"
awk -v t="$TOTAL" -v th="$THRESHOLD" 'BEGIN {
    if (t + 0 < th + 0) { print "FAIL: coverage below threshold"; exit 1 }
    print "PASS: coverage gate satisfied"
}'
