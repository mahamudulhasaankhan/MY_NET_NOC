#!/bin/bash
# Daily HA health check: runs verify-ha.sh + backup freshness check.
# On failure, posts an alert to the Telegram relay (same path as Grafana alerts).
set -u
LOG_TAG="ha-daily-check"
FAILED=0

echo "[$LOG_TAG] starting $(date -Is)"

OUT=$(/usr/local/bin/verify-ha.sh 2>&1)
RC=$?
echo "$OUT"
if [ "$RC" -ne 0 ]; then
    FAILED=1
fi

BACKUP_DIR=/var/backups/nms
LATEST=$(ls -t "$BACKUP_DIR"/nms_backup_*.tar.gz 2>/dev/null | head -1)
if [ -z "$LATEST" ]; then
    echo "[$LOG_TAG] ERROR: no backup found in $BACKUP_DIR"
    FAILED=1
else
    AGE_H=$(( ($(date +%s) - $(stat -c %Y "$LATEST")) / 3600 ))
    echo "[$LOG_TAG] latest backup: $(basename "$LATEST") (${AGE_H}h old)"
    if [ "$AGE_H" -gt 36 ]; then
        echo "[$LOG_TAG] ERROR: backup is ${AGE_H}h old"
        FAILED=1
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    MSG=$(echo "$OUT" | grep -E "FAIL|ERROR" | head -5 | tr '\n' '; ')
    curl -s -m 10 -X POST http://127.0.0.1:8098/ -H "Content-Type: application/json" \
        -d "{\"title\":\"NMS Daily HA Check FAILED\",\"message\":\"${MSG:-see journal}\",\"state\":\"alerting\"}" \
        >/dev/null 2>&1
    echo "[$LOG_TAG] alert posted to telegram relay"
    exit 1
fi

echo "[$LOG_TAG] all good"
exit 0
