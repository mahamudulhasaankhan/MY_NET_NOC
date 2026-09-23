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

# Postgres HA: both poolers and the front-door proxy must be running. The
# proxy is what host clients (engines, backup) and RADIUS connect to; a
# missing standby pooler would silently remove pooler-level redundancy.
for pair in pg-pgpool:pgpool pg-pgpool-2:pgpool-2 pgpool-proxy:pgpool-proxy; do
    c="${pair%%:*}"; svc="${pair##*:}"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
        echo "[$(date)] Watchdog detected $c down! Auto-healing..." >> "$LOG"
        tg_alert "🛠️ <b>NMS Watchdog</b>: <code>$c</code> was down — restarting DB stack."
        cd "$REPO_ROOT/infra/deploy/db_cluster" && sudo docker compose up -d "$svc" 2>/dev/null || true
    fi
done

# Postgres HA pooler self-heal — two failure modes, one proven fix:
#   1) pooler UNHEALTHY, e.g. "all backend nodes are down" right after a hard
#      reboot: /tmp/pgpool_status (stale node-state) SURVIVES docker restart
#      because the container filesystem is preserved, and docker compose up -d
#      is a no-op for an existing container, so the unhealthy state persisted
#      for hours (2026-09-22 incident).
#   2) backends healthy but a node still marked "down" (pgpool never
#      auto-re-attaches after the node recovers).
# pcp_attach_node is unusable here (PCP TCP socket is not exposed by this
# image). The proven healer: delete /tmp/pgpool_status and restart the pooler
# — on a fresh start its health checks re-detect every backend automatically.
# Telegram alert is rate-limited (once per hour) to avoid spam.
NOW=$(date +%s)
HEAL_LAST=$(stat -c %Y /var/run/nms_pgpool_heal 2>/dev/null || echo 0)
for c in pg-pgpool pg-pgpool-2; do
    HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$c" 2>/dev/null)
    DOWN=$(docker exec "$c" psql -h 127.0.0.1 -p 5432 -U rnd_user -d rnd_db -tAc \
        "SHOW pool_nodes" 2>/dev/null | awk -F'|' '$4=="down"{print $1}')
    if [ "$HEALTH" = "unhealthy" ] || [ -n "$DOWN" ]; then
        REASON="unhealthy"
        [ -n "$DOWN" ] && REASON="backend node(s) down: ${DOWN// /,}"
        if [ $((NOW - HEAL_LAST)) -gt 3600 ]; then
            tg_alert "🛠️ <b>NMS Watchdog</b>: <code>$c</code> $REASON — clearing stale pgpool status + restarting pooler."
            touch /var/run/nms_pgpool_heal
            echo "[$(date)] Watchdog healing $c ($REASON): rm /tmp/pgpool_status + docker restart" >> "$LOG"
        fi
        docker exec "$c" rm -f /tmp/pgpool_status 2>/dev/null || true
        sudo docker restart "$c" >/dev/null 2>&1 || true
    fi
done

# Postgres HA: split-brain guard. failover.sh promotes the standby but the
# old primary, once it restarts, is still a PRIMARY (no auto-rejoin). Two
# nodes answering as primary = split-brain. Alert ONCE per incident (state
# file); the fix is a deliberate rejoin-standby.sh run (resyncs stale node).
P0_ROLE=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" pg-0 psql -h 127.0.0.1 \
    -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" \
    -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d '[:space:]')
P1_ROLE=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" pg-1 psql -h 127.0.0.1 \
    -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" \
    -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d '[:space:]')
NPRIM=$(printf '%s\n%s\n' "$P0_ROLE" "$P1_ROLE" | grep -c '^f$' || true)
SB_STATE=/var/run/nms_pg_splitbrain
if [ "${NPRIM:-0}" -ge 2 ]; then
    echo "[$(date)] SPLIT-BRAIN: pg-0 and pg-1 BOTH primary!" >> "$LOG"
    if [ ! -f "$SB_STATE" ]; then
        tg_alert "🚨 <b>PG SPLIT-BRAIN</b>: both nodes are PRIMARY. Fix: <code>sudo bash $REPO_ROOT/infra/deploy/db_cluster/rejoin-standby.sh pg-0|pg-1</code>"
    fi
    touch "$SB_STATE"
else
    rm -f "$SB_STATE"
fi

# Backup freshness guard: the nightly backup once silently failed for 31
# days. If the newest archive is older than 26h, alert ONCE until a fresh
# archive appears.
NEWEST_BK=$(ls -t /var/backups/nms/nms_backup_*.tar.gz 2>/dev/null | head -1)
BK_STATE=/var/run/nms_backup_stale
if [ -n "$NEWEST_BK" ]; then
    BK_AGE=$(( $(date +%s) - $(stat -c %Y "$NEWEST_BK") ))
    if [ "$BK_AGE" -gt 93600 ]; then
        echo "[$(date)] BACKUP STALE: $(basename "$NEWEST_BK") is $((BK_AGE/3600))h old" >> "$LOG"
        if [ ! -f "$BK_STATE" ]; then
            tg_alert "🚨 <b>NMS Backup STALE</b>: newest backup is $((BK_AGE/3600))h old — nightly backup is FAILING. Check /var/log/nms_backup.log"
        fi
        touch "$BK_STATE"
    else
        rm -f "$BK_STATE"
    fi
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
