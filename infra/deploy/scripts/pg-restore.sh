#!/usr/bin/env bash
# pg-restore.sh — bring a failed primary back as a REPLICA of the current
# primary after a pgpool failover (e.g. pg-0 died, pg-1 was promoted).
#
# Usage: sudo deploy/scripts/pg-restore.sh <old-primary> <current-primary>
#   e.g. sudo deploy/scripts/pg-restore.sh pg-0 pg-1
#
# The old primary's timeline has diverged, so its data volume is wiped and
# bitnami re-clones from the current primary. Add/change to empty afterwards.
set -euo pipefail

OLD="${1:-pg-0}"
NEW="${2:-pg-1}"
REPO_ROOT="${NMS_REPO:-}"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/infra/deploy/db_cluster"

echo "==> Stopping and removing $OLD (data volume will be wiped)"
docker stop "$OLD"
docker rm "$OLD"

echo "==> Wiping ${OLD}_data volume"
docker volume rm "${COMPOSE_DIR##*/}_${OLD}_data" || docker volume rm "${OLD}_data"
if docker volume inspect "${COMPOSE_DIR##*/}_${OLD}_data" >/dev/null 2>&1; then
    echo "ERROR: volume ${COMPOSE_DIR##*/}_${OLD}_data still exists — refusing to re-clone onto stale data!" >&2
    exit 1
fi

echo "==> Recreating $OLD as replica of $NEW"
cd "$COMPOSE_DIR"
NODE_ID="${OLD##*-}"   # pg-0 -> 0, pg-1 -> 1
# Per-node env: PG0_* for pg-0, PG1_* for pg-1. --no-deps: never touch the
# other node (compose would otherwise recreate it, causing a second failover).
export "PG${NODE_ID}_REPL_MODE=slave" "PG${NODE_ID}_MASTER_HOST=$NEW"
docker compose up -d --no-deps "$OLD"
unset "PG${NODE_ID}_REPL_MODE" "PG${NODE_ID}_MASTER_HOST"

echo "==> Waiting for catch-up..."
for i in $(seq 1 30); do
    LAG=$(docker exec -e PGPASSWORD="${PG_PASSWORD:?set PG_PASSWORD}" "$OLD" psql -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" -tAc "SELECT pg_is_in_recovery()" 2>/dev/null || true)
    if [ "$LAG" = "t" ]; then
        echo "==> $OLD is back in streaming standby mode"
        break
    fi
    sleep 2
done

# pgpool keeps a stale "down" status for the node after failover; re-attach it
# so it is load-balanced again (needs PCP creds from db_cluster/.env).
docker exec pg-pgpool sh -c "echo '${PGPOOL_PCP_PASSWORD:-admin}' | /opt/pgpool-II/bin/pcp_attach_node -h 127.0.0.1 -p 9898 -U ${PGPOOL_PCP_USER:-admin} -W -n ${NODE_ID}" 2>/dev/null \
    && echo "==> Attached $OLD back into pgpool (node ${NODE_ID})"

echo "==> Verify: SHOW pool_nodes"
