#!/bin/bash
# Applies Redis auth to the Sentinel trio configs (mounted into the sentinel
# containers). Reads REDIS_PASSWORD from /etc/nms/nms.env. Idempotent.
set -e
if [ -r /etc/nms/nms.env ]; then
    set -a; source /etc/nms/nms.env; set +a
fi
REDIS_PASSWORD="${REDIS_PASSWORD:?REDIS_PASSWORD not set}"

BASE="$(cd "$(dirname "$0")/../nms_stack/sentinel" && pwd)"
# Ensure runtime dirs + base conf exist (fresh bundle may lack them).
for d in s1 s2 s3; do
    mkdir -p "$BASE/$d"
    if [[ ! -f "$BASE/$d/sentinel.conf" && -f "$BASE/sentinel.conf.template" ]]; then
        case "$d" in
            s1) port=26379 ;;
            s2) port=26380 ;;
            s3) port=26381 ;;
            *)  port=26379 ;;
        esac
        sed "s/^port .*/port ${port}/" "$BASE/sentinel.conf.template" > "$BASE/$d/sentinel.conf"
        chown 999:999 "$BASE/$d/sentinel.conf" 2>/dev/null || true
        chmod 640 "$BASE/$d/sentinel.conf"
    fi
done
for d in s1 s2 s3; do
    CONF="$BASE/$d/sentinel.conf"
    OWNER="$(id -un)"
    [ -w "$CONF" ] || sudo chown "$OWNER" "$CONF"
    # Redis 7.4+ sentinels rewrite the conf with the default user as an ACL
    # line (`user default on #<sha256>`), which OVERRIDES requirepass when
    # the old hash lingers — dropping only requirepass then re-adding it is
    # NOT enough. Remove any stale ACL default-user line so the fresh
    # requirepass below is authoritative; the sentinel re-emits the ACL line
    # with the correct hash on its next config save.
    sed -i '/^requirepass /d; /^masterauth /d; /^sentinel auth-pass /d; /^user default /d' "$CONF"
    {
        echo "requirepass $REDIS_PASSWORD"
        echo "masterauth $REDIS_PASSWORD"
        echo "sentinel auth-pass mymaster $REDIS_PASSWORD"
    } >> "$CONF"
    echo "auth applied: $CONF"
done
