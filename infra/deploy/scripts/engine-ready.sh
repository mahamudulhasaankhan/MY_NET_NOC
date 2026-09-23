#!/usr/bin/env bash
# Engine readiness gate: waits until the DB front door (pgpool-proxy on
# 127.0.0.1:6432, fallback: pooler-1 on 5432), Redis (6380) and NATS (4222)
# answer before the engine instance starts. Prevents crash-restart races right
# after a host reboot (docker stack comes up after systemd started the engine).
set -euo pipefail

check_tcp() {
    local host="$1" port="$2"
    (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null
}

for i in $(seq 1 60); do
    if (check_tcp 127.0.0.1 6432 || check_tcp 127.0.0.1 15432) && check_tcp 127.0.0.1 6380 && check_tcp 127.0.0.1 4222; then
        # Pre-flight gate: verify/apply DB schema migrations before live services boot.
        # Migrations must run on the PRIMARY node: through the pooler, the early
        # statements of a transaction could otherwise be load-balanced to the
        # standby. Resolve the current primary via the pooler and override the
        # target (works after failovers, unlike a hardcoded node port).
        PRIM=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" pg-pgpool psql -h 127.0.0.1 -p 5432 \
            -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" -tAc "SHOW pool_nodes" 2>/dev/null \
            | awk -F'|' '$7=="primary"{print $2}' || true)
        case "$PRIM" in
            pg-0) export MIGRATION_DATABASE_URL="postgresql://${PG_USERNAME:-rnd_user}:${PG_PASSWORD:-}@localhost:15432/${PG_DATABASE:-rnd_db}?sslmode=disable" ;;
            pg-1) export MIGRATION_DATABASE_URL="postgresql://${PG_USERNAME:-rnd_user}:${PG_PASSWORD:-}@localhost:25432/${PG_DATABASE:-rnd_db}?sslmode=disable" ;;
        esac
        if command -v /usr/local/bin/nms_engine >/dev/null 2>&1; then
            /usr/local/bin/nms_engine --migrate || true
        fi
        exit 0
    fi
    sleep 1
done
echo "engine-ready: timeout waiting for db front door (6432/pg-0 15432), redis:6380, nats:4222" >&2
exit 1
