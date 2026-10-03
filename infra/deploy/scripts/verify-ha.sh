#!/bin/bash
# HA verification: run after reboot or any cluster incident.
# Prints a compact status of all HA layers. Exits 1 if any check fails.
REPO_ROOT="${NMS_REPO:-}"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -r /etc/nms/nms.env ]; then
    set -a; source /etc/nms/nms.env; set +a
fi
FAIL=0
check() { # check <label> <status>  (status=OK -> pass)
    if [ "$2" = "OK" ]; then
        printf "%-28s %s\n" "$1" "OK"
    else
        printf "%-28s %s\n" "$1" "FAIL ($2)"
        FAIL=1
    fi
}

# 1. containers
EXPECT=23
N=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
[ "$N" -ge "$EXPECT" ] && check "containers up ($N/$EXPECT)" OK || check "containers up" "$N/$EXPECT"

# 2. Tier-B: Web API engines (5 instances, all must be active)
ACTIVE_WEB=$(systemctl is-active nms_engine@8000 nms_engine@8001 nms_engine@8002 nms_engine@8003 nms_engine@8004 2>/dev/null | tr '\n' ' ')
[ "$ACTIVE_WEB" = "active active active active active " ] && check "web cluster 8000-8004" OK || check "web cluster 8000-8004" "$ACTIVE_WEB"

# 2c. Tier-A: Polling worker engines (3 instances, all must be active)
ACTIVE_WORKER=$(systemctl is-active nms_worker@9000 nms_worker@9001 nms_worker@9002 2>/dev/null | tr '\n' ' ')
[ "$ACTIVE_WORKER" = "active active active " ] && check "poller cluster 9000-9002" OK || check "poller cluster 9000-9002" "$ACTIVE_WORKER"

# 2b. crash loops (restarting containers count as "up" in docker ps — check RestartCount).
# Only count as crash-looping if the container restarted RECENTLY (old restarts from
# past incidents leave the counter high forever and would fail the check spuriously).
LOOPERS=""
NOW_EPOCH=$(date +%s)
for c in nms-freeradius pg-pgpool pg-pgpool-2 pgpool-proxy nms-nats nms-clickhouse nms-redis-cache nms-redis-replica; do
    RC=$(docker inspect "$c" --format '{{.RestartCount}}' 2>/dev/null)
    STARTED=$(date -d "$(docker inspect "$c" --format '{{.State.StartedAt}}' 2>/dev/null)" +%s 2>/dev/null)
    [ -z "$STARTED" ] && continue
    AGE=$(( NOW_EPOCH - STARTED ))
    [ -n "$RC" ] && [ "$RC" -gt 5 ] && [ "$AGE" -lt 600 ] && LOOPERS="$LOOPERS $c($RC)"
done
[ -z "$LOOPERS" ] && check "no container crash loops" OK || check "no container crash loops" "$LOOPERS"

# 3. API health: nginx edge alive (SPA served through WAF) + every engine instance healthy
CODE=$(curl -sk -A "nms-deploy-healthcheck" https://localhost/health -o /dev/null -w "%{http_code}" 2>/dev/null)
[ "$CODE" = "200" ] && check "nginx edge (443)" OK || check "nginx edge (443)" "HTTP $CODE"
BAD=""
for p in 8000 8001 8002 8003 8004; do
    C=$(curl -s -m 3 "http://127.0.0.1:$p/health" -o /dev/null -w "%{http_code}" 2>/dev/null)
    [ "$C" = "200" ] || BAD="$BAD $p:$C"
done
[ -z "$BAD" ] && check "engine /health (5 instances)" OK || check "engine /health" "$BAD"

# 4. Redis HA: sentinel master + replica link (master/replica ports may swap after failover)
MASTER_PORT=$(docker exec nms-redis-sentinel-1 redis-cli -a "$REDIS_PASSWORD" -p 26379 sentinel get-master-addr-by-name mymaster 2>/dev/null | sed -n 2p)
[ -n "$MASTER_PORT" ] && check "sentinel master (127.0.0.1:$MASTER_PORT)" OK || check "sentinel master" "no master"
REPLICA_PORT=$([ "$MASTER_PORT" = "6380" ] && echo 6381 || echo 6380)
RLINK=$(docker exec nms-redis-sentinel-1 redis-cli -a "$REDIS_PASSWORD" -p "$REPLICA_PORT" info replication 2>/dev/null | grep -E "^master_link_status" | cut -d: -f2 | tr -d ' \r\n')
[ "$RLINK" = "up" ] && check "redis replica link" OK || check "redis replica link" "$RLINK"

# 5. Leader elections (separate Redis keys for each cluster)
POLL_LEADER=$(docker exec nms-redis-sentinel-1 redis-cli -a "$REDIS_PASSWORD" -p "$MASTER_PORT" get nms:leader:poller 2>/dev/null | head -1)
# Polling cluster has real leader election (workers env: NMS_LEADER_KEY)
[ -n "$POLL_LEADER" ] && check "polling leader ($POLL_LEADER)" OK || check "polling leader" "no nms:leader:poller key"

# 6. pgpool pool_nodes
POOL=$(docker exec pg-pgpool psql -h 127.0.0.1 -p 5432 -U rnd_user -d rnd_db -tAc "SHOW pool_nodes" 2>/dev/null | awk -F'|' '{printf "%s:%s ", $1, $4}')
[ "$(echo "$POOL" | grep -oE '[0-9]+:up' | sort -u | wc -l)" -ge 2 ] && check "pool_nodes ($POOL)" OK || check "pool_nodes" "$POOL"

# 6b. DB front door: host TCP + an end-to-end SELECT through pgpool-proxy
# (resolved by the standby pooler container, i.e. proves the whole chain
#  client -> proxy -> active pooler -> primary/standby -> rows).
if (exec 3<>/dev/tcp/127.0.0.1/6432) 2>/dev/null; then
    check "db front door tcp (6432)" OK
else
    check "db front door tcp (6432)" "not listening"
fi
FRONT=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" pg-pgpool-2 psql -h pgpool-ha -p 5432 \
    -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" -tAc "SELECT 1" 2>/dev/null | tr -d '[:space:]')
[ "$FRONT" = "1" ] && check "db front door query (pgpool-ha)" OK || check "db front door query" "no answer through proxy"

# 6c. The engines must USE the front door: a DATABASE_URL pointing at a single
# PG node (15432/25432) or a single pooler port (5432) would silently recreate
# the DB single point of failure.
case "${DATABASE_URL:-}" in
    *:6432/*) check "DATABASE_URL via front door (6432)" OK ;;
    *)        check "DATABASE_URL via front door (6432)" "not 6432: ${DATABASE_URL%%\?*}" ;;
esac

# 7. PG replication live test: write via pgpool, read on the CURRENT standby
PRIMARY=$(docker exec pg-pgpool psql -h 127.0.0.1 -p 5432 -U rnd_user -d rnd_db -tAc \
    "SHOW pool_nodes" 2>/dev/null | awk -F'|' '$7=="primary"{print $2}')
STANDBY=$(docker exec pg-pgpool psql -h 127.0.0.1 -p 5432 -U rnd_user -d rnd_db -tAc \
    "SHOW pool_nodes" 2>/dev/null | awk -F'|' '$7=="standby"{print $2}')
if [ -z "$STANDBY" ]; then
    check "PG replication" "no standby node"
else
    docker exec pg-pgpool psql -h 127.0.0.1 -p 5432 -U rnd_user -d rnd_db -tAc \
        "INSERT INTO settings(key,value) VALUES('verify_ha','ok') ON CONFLICT (key) DO UPDATE SET value='ok'" >/dev/null 2>&1
    sleep 2
    R=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" "$STANDBY" psql -U rnd_user -d rnd_db -tAc \
        "SELECT value FROM settings WHERE key='verify_ha'" 2>/dev/null)
    [ "$R" = "ok" ] && check "PG replication ($PRIMARY->$STANDBY)" OK || check "PG replication" "standby missing write"
fi

# 8. Replication hba entry on the primary (needed for pg_basebackup/pg_rewind)
HBA=$(docker exec "$PRIMARY" sh -c 'grep -cE "^host[[:space:]]+replication" /opt/bitnami/postgresql/conf/pg_hba.conf' 2>/dev/null || echo 0)
[ "${HBA:-0}" -ge 1 ] && check "replication hba ($PRIMARY)" OK || check "replication hba" "missing 'host replication' on $PRIMARY"

# 9. ClickHouse ingestion: auth + all 4 raw tables present
if [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then
    check "clickhouse auth" "CLICKHOUSE_PASSWORD missing (run with sudo: /etc/nms/nms.env is root-only)"
else
    CH_AUTH=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:8123/?query=SELECT+1&user=default&password=${CLICKHOUSE_PASSWORD:-}")
    [ "$CH_AUTH" = "200" ] && check "clickhouse auth" OK || check "clickhouse auth" "HTTP $CH_AUTH"
    CH_TABLES=$(curl -s -m 5 "http://127.0.0.1:8123/?query=SELECT+count()+FROM+system.tables+WHERE+database%3D'default'+AND+name+IN('syslog_raw','netflow_raw','sflow_raw','radius_acct_raw')&user=default&password=${CLICKHOUSE_PASSWORD:-}" 2>/dev/null)
    [ "$CH_TABLES" = "4" ] && check "clickhouse tables (4/4)" OK || check "clickhouse tables" "$CH_TABLES"
fi

# 10. RADIUS auth path: probe through the UDP balancer. A Reject/Accept for
# the probe user PROVES the full pipeline (balancer -> freeradius -> DB) is
# alive; a timeout means customer PPPoE authentication is at risk.
RB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' nms-radius-balancer 2>/dev/null | awk '{print $1}')
RSECRET=$(grep -E '^RADIUS_NAS_SECRET=' "$REPO_ROOT/infra/deploy/nms_stack/.env" 2>/dev/null | head -1 | cut -d= -f2-)
if [ -n "$RB_IP" ] && [ -n "$RSECRET" ]; then
    RR=$(echo 'User-Name=ha_probe,User-Password=probe123' | \
        docker exec -i nms-freeradius radclient "$RB_IP:1812" auth "$RSECRET" -c 1 2>&1)
    case "$RR" in
        *Access-Reject*|*Access-Accept*) check "radius auth path (balancer->backend->DB)" OK ;;
        *) check "radius auth path (balancer->backend->DB)" "no RADIUS response" ;;
    esac
else
    check "radius auth path (balancer->backend->DB)" "balancer or NAS secret unavailable"
fi

echo
[ "$FAIL" = "0" ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
