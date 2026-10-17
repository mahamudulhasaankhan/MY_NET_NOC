#!/bin/bash
# Renders secret-bearing config files from /etc/nms/nms.env (root-only).
# No secrets are committed: templates carry __PLACEHOLDER__ markers and the
# rendered artifacts are gitignored.
#
# Requires: CLICKHOUSE_PASSWORD (used by engine, backup, verify-ha, CH itself)
# Idempotent; run before `docker compose up -d clickhouse`.
set -euo pipefail

if [ -r /etc/nms/nms.env ]; then
    set -a; source /etc/nms/nms.env; set +a
fi
: "${CLICKHOUSE_PASSWORD:?CLICKHOUSE_PASSWORD not set}"

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../nms_stack" && pwd)"

render() {
    local tmpl="$1" out="$2"
    sed -e "s|__CLICKHOUSE_PASSWORD__|${CLICKHOUSE_PASSWORD}|g" \
        "$tmpl" > "$out"
    if cmp -s "$tmpl" "$out"; then
        echo "unchanged: $out"
    else
        echo "rendered:  $out"
    fi
}

render "$STACK_DIR/clickhouse-users.d/99-nms-password.xml.template" \
       "$STACK_DIR/clickhouse-users.d/99-nms-password.xml"

echo "Apply: sudo docker compose -f $STACK_DIR/docker-compose.yml up -d clickhouse"
