#!/bin/bash
# NMS Auto-Healing Watchdog (5 HA instances: 8000-8004)

# Load Telegram credentials and repo location for failover alerts
if [ -r /etc/nms/nms.env ]; then
    set -a
    source /etc/nms/nms.env
    set +a
fi
REPO_ROOT="${NMS_REPO:-}"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG=/var/log/nms_watchdog.log

# pgpool PCP/DB password (rotated, lives in the gitignored stack .env)
if [ -r "$REPO_ROOT/infra/deploy/db_cluster/.env" ]; then
    set -a
    source "$REPO_ROOT/infra/deploy/db_cluster/.env"
    set +a
fi

# Fallback: Telegram creds configured via the UI settings page (DB)
get_tg_creds() {
    if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT:-}" ]; then
        return
    fi
    local out
    out=$(psql "${DATABASE_URL:-}" -tAc "SELECT value FROM settings WHERE key='telegram_token'" 2>/dev/null)
    [ -n "$out" ] && TELEGRAM_TOKEN="$out"
    out=$(psql "${DATABASE_URL:-}" -tAc "SELECT value FROM settings WHERE key='telegram_chat_id'" 2>/dev/null)
    [ -n "$out" ] && TELEGRAM_CHAT="$out"
}
get_tg_creds

tg_alert() {
    if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT:-}" ]; then
        curl -s -m 5 "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT}" -d "text=$1" -d "parse_mode=HTML" >/dev/null 2>&1 || true
    fi
}

# Ensure all 5 API engine instances are up (8000-8004)
for port in 8000 8001 8002 8003 8004; do
    if ! systemctl is-active --quiet "nms_engine@${port}.service"; then
        echo "[$(date)] Watchdog detected nms_engine@${port} down! Auto-healing..." >> "$LOG"
        tg_alert "🛠️ <b>NMS Watchdog</b>: engine instance <code>${port}</code> was down — auto-restarting."
        sudo systemctl start "nms_engine@${port}.service"
    fi
done

# Ensure all 3 Polling Worker instances are up (9000-9002)
for port in 9000 9001 9002; do
    if ! systemctl is-active --quiet "nms_worker@${port}.service"; then
        echo "[$(date)] Watchdog detected nms_worker@${port} down! Auto-healing..." >> "$LOG"
        tg_alert "🛠️ <b>NMS Watchdog</b>: worker instance <code>${port}</code> was down — auto-restarting."
        sudo systemctl start "nms_worker@${port}.service"
    fi
done

if ! systemctl is-active --quiet nginx; then
    echo "[$(date)] Watchdog detected nginx down! Auto-healing..." >> "$LOG"
    tg_alert "🛠️ <b>NMS Watchdog</b>: nginx was down — auto-restarting."
    sudo systemctl restart nginx
fi

if ! systemctl is-active --quiet redis-server.service 2>/dev/null && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q redis; then
    echo "[$(date)] Watchdog detected redis down! Auto-healing..." >> "$LOG"
    tg_alert "🛠️ <b>NMS Watchdog</b>: Redis was down — attempting auto-restart."
    sudo systemctl restart redis-server.service 2>/dev/null || true
fi

# Postgres HA: pgpool must serve; if it is down, the engine loses its DB
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q pg-pgpool; then
    echo "[$(date)] Watchdog detected pgpool down! Auto-healing..." >> "$LOG"
    tg_alert "🛠️ <b>NMS Watchdog</b>: pgpool was down — restarting cluster."
    cd "$REPO_ROOT/infra/deploy/db_cluster" && sudo docker compose up -d pgpool 2>/dev/null || true
fi

# Postgres HA: a running-but-UNHEALTHY pgpool (e.g. health_check_password went
# stale after a DB password rotation, or a stuck node status) poisons every
# new connection and re-marks healthy nodes down. Recreate with the current
# .env so pgpool.conf is regenerated and /tmp/pgpool_status is reset.
PGPOOL_HEALTH=$(docker inspect --format '{{.State.Health.Status}}' pg-pgpool 2>/dev/null)
if [ -n "$PGPOOL_HEALTH" ] && [ "$PGPOOL_HEALTH" != "healthy" ]; then
    echo "[$(date)] Watchdog detected pgpool UNHEALTHY (${PGPOOL_HEALTH})! Recreating with current env..." >> "$LOG"
    cd "$REPO_ROOT/infra/deploy/db_cluster" && sudo docker compose up -d pgpool 2>/dev/null || true
fi

# Postgres HA: re-attach pgpool backend nodes that are healthy but still marked
# down (pgpool does not auto-attach; required after reboots or node restarts).
# Only touches nodes that are actually down, so live connections are untouched.
DOWN_NODES=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" pg-pgpool psql -h 127.0.0.1 -p 5432 -U rnd_user -d rnd_db -tAc \
    "SHOW pool_nodes" 2>/dev/null | awk -F'|' '$4=="down"{print $1}')
if [ -n "$DOWN_NODES" ]; then
    for node_id in $DOWN_NODES; do
        echo "[$(date)] Watchdog re-attaching pgpool node ${node_id}..." >> "$LOG"
        if echo "${PGPOOL_PCP_PASSWORD:-admin}" | docker exec -i pg-pgpool /opt/pgpool-II/bin/pcp_attach_node \
            -h 127.0.0.1 -p 9898 -U admin -W -n "$node_id" 2>/dev/null | grep -q Successful; then
            echo "[$(date)] pgpool node ${node_id} attached." >> "$LOG"
            tg_alert "🛠️ <b>NMS Watchdog</b>: re-attached pgpool backend node <code>${node_id}</code>."
        else
            echo "[$(date)] pgpool node ${node_id} attach FAILED (bad PCP creds?)" >> "$LOG"
        fi
    done
fi

# Full HA sweep: verify-ha checks every layer (API, redis sentinel, leader,
# pgpool, replication, hba). Alert ONCE per FAIL->OK transition (state file).
HA_STATE=/var/run/nms_ha_status
HA_OUT=$(sudo bash /usr/local/bin/verify-ha.sh 2>/dev/null)
if [ $? -ne 0 ]; then
    FAILS=$(echo "$HA_OUT" | grep -E "FAIL" | tr '\n' '; ')
    if [ ! -f "$HA_STATE" ]; then
        echo "[$(date)] HA FAIL: $FAILS" >> "$LOG"
        tg_alert "🚨 <b>NMS HA Check FAILED</b>: $FAILS"
    fi
    touch "$HA_STATE"
else
    if [ -f "$HA_STATE" ]; then
        echo "[$(date)] HA recovered - ALL CHECKS PASSED" >> "$LOG"
        tg_alert "✅ <b>NMS HA Recovered</b>: ALL CHECKS PASSED"
    fi
    rm -f "$HA_STATE"
fi
