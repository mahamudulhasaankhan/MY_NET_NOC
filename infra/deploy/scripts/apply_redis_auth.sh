#!/bin/bash
# Applies Redis auth to the Sentinel trio configs (mounted into the sentinel
# containers). Reads REDIS_PASSWORD from /etc/nms/nms.env. Idempotent.
set -e
if [ -r /etc/nms/nms.env ]; then
    set -a; source /etc/nms/nms.env; set +a
fi
REDIS_PASSWORD="${REDIS_PASSWORD:?REDIS_PASSWORD not set}"

BASE="$(cd "$(dirname "$0")/../nms_stack/sentinel" && pwd)"
for d in s1 s2 s3; do
    CONF="$BASE/$d/sentinel.conf"
    OWNER="$(id -un)"
    [ -w "$CONF" ] || sudo chown "$OWNER" "$CONF"
    sed -i '/^requirepass /d; /^masterauth /d; /^sentinel auth-pass /d' "$CONF"
    {
        echo "requirepass $REDIS_PASSWORD"
        echo "masterauth $REDIS_PASSWORD"
        echo "sentinel auth-pass mymaster $REDIS_PASSWORD"
    } >> "$CONF"
    echo "auth applied: $CONF"
done
