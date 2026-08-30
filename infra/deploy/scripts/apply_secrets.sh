#!/bin/bash
# Renders secret-bearing config files from /etc/nms/nms.env (root-only).
# No secrets are committed: templates carry __PLACEHOLDER__ markers and the
# rendered artifacts are gitignored.
#
# Requires: CLICKHOUSE_PASSWORD (used by engine, backup, verify-ha, CH itself)
#           GRAFANA_CH_PASSWORD (grafana user in ClickHouse + datasource)
# Idempotent; run before `docker compose up -d clickhouse grafana`.
set -euo pipefail

if [ -r /etc/nms/nms.env ]; then
    set -a; source /etc/nms/nms.env; set +a
fi
: "${CLICKHOUSE_PASSWORD:?CLICKHOUSE_PASSWORD not set}"
: "${GRAFANA_CH_PASSWORD:?GRAFANA_CH_PASSWORD not set}"

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../nms_stack" && pwd)"

render() {
    local tmpl="$1" out="$2"
    sed -e "s|__CLICKHOUSE_PASSWORD__|${CLICKHOUSE_PASSWORD}|g" \
        -e "s|__GRAFANA_CH_PASSWORD__|${GRAFANA_CH_PASSWORD}|g" \
        "$tmpl" > "$out"
    if cmp -s "$tmpl" "$out"; then
        echo "unchanged: $out"
    else
        echo "rendered:  $out"
    fi
}

render "$STACK_DIR/clickhouse-users.d/99-nms-password.xml.template" \
       "$STACK_DIR/clickhouse-users.d/99-nms-password.xml"
render "$STACK_DIR/grafana-provisioning/datasources/clickhouse.yaml.template" \
       "$STACK_DIR/grafana-provisioning/datasources/clickhouse.yaml"
render "$STACK_DIR/grafana-user.sql.template" \
       "$STACK_DIR/grafana-user.sql"

echo "Apply: sudo docker compose -f $STACK_DIR/docker-compose.yml up -d clickhouse grafana"
echo "And (first run): docker exec nms-clickhouse clickhouse-client --multiquery < $STACK_DIR/grafana-user.sql"
