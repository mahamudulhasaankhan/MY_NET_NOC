#!/usr/bin/env bash
# Enterprise Split-Role HA deploy for nms_engine (8 instances total)
#
# Architecture:
#   Tier-B (Web API Cluster): 5 instances on :8000-:8004 (nms_engine@PORT)
#     → --api mode only; nginx least_conn Active-Active load balancing
#
#   Tier-A (Polling Worker Cluster): 3 instances on :9000-:9002 (nms_worker@PORT)
#     → --poller --bgp --syslog --netflow; leader-elected, only one polls at a time
#
# Zero-downtime: nginx skips any restarting instance automatically (max_fails=2).
# Rollback: previous binary is preserved and re-installed on any health check failure.
#
# Usage: zero-downtime-deploy.sh <path-to-new-binary>
set -euo pipefail

BINARY="${1:?usage: $0 <path-to-new-binary>}"

WEB_INSTANCES=(8000 8001 8002 8003 8004)
WORKER_INSTANCES=(9000 9001 9002)

WEB_ENV_DIR=/etc/nms/instances
WORKER_ENV_DIR=/etc/nms/workers
PREV_BINARY=/tmp/nms_engine.prev
LOG_PREFIX="[ha-deploy]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${NMS_REPO:-}"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

log() { echo "$LOG_PREFIX $*"; }

rollback() {
    local reason="$1"
    log "ROLLBACK ($reason): restoring previous binary"
    if [ -f "$PREV_BINARY" ]; then
        sudo install -m 0755 "$PREV_BINARY" /usr/local/bin/nms_engine
    fi
    log "ROLLBACK: restarting all web instances on previous binary"
    for port in "${WEB_INSTANCES[@]}"; do
        sudo systemctl restart "nms_engine@${port}" 2>/dev/null || true
    done
    log "ROLLBACK: restarting all worker instances on previous binary"
    for port in "${WORKER_INSTANCES[@]}"; do
        sudo systemctl restart "nms_worker@${port}" 2>/dev/null || true
    done
    sudo systemctl reload nginx 2>/dev/null || true
    log "ROLLBACK complete - previous version restored"
    exit 1
}

wait_healthy() {
    local port="$1"
    for i in $(seq 1 60); do
        if curl -sf --max-time 2 -A "nms-deploy-healthcheck" "http://127.0.0.1:${port}/health" > /dev/null 2>&1; then
            log ":${port} healthy (attempt ${i})"
            return 0
        fi
        sleep 1
    done
    log "ERROR: :${port} not healthy after 60s"
    return 1
}

if [ ! -f "$BINARY" ]; then
    echo "ERROR: binary not found: $BINARY"
    exit 1
fi

log "pausing watchdog timer during deploy (avoid restart race)"
sudo systemctl stop nms_watchdog.timer 2>/dev/null || true
trap 'sudo systemctl start nms_watchdog.timer 2>/dev/null || true' EXIT

# ─────────────────────────────────────────────────────────────────
# Ensure per-instance env files exist
# ─────────────────────────────────────────────────────────────────
log "ensuring Tier-B (web) per-instance env files"
sudo mkdir -p "$WEB_ENV_DIR"
for i in "${!WEB_INSTANCES[@]}"; do
    port="${WEB_INSTANCES[$i]}"
    env_file="$WEB_ENV_DIR/${port}.env"
    if [ ! -f "$env_file" ]; then
        printf 'NMS_LEADER_PRIORITY=999\nNMS_LEADER_KEY=nms:leader:web\n' | sudo tee "$env_file" > /dev/null
        log "  created $env_file"
    fi
done

log "ensuring Tier-A (polling) per-instance env files"
sudo mkdir -p "$WORKER_ENV_DIR"
SYSLOG_BASE=1514; NETFLOW_BASE=2155; SFLOW_BASE=26343
for i in "${!WORKER_INSTANCES[@]}"; do
    port="${WORKER_INSTANCES[$i]}"
    env_file="$WORKER_ENV_DIR/${port}.env"
    if [ ! -f "$env_file" ]; then
        printf 'SYSLOG_PORT=%d\nNETFLOW_PORT=%d\nSFLOW_PORT=%d\nNMS_LEADER_PRIORITY=%d\nNMS_LEADER_KEY=nms:leader:poller\n' \
            "$((SYSLOG_BASE + i))" "$((NETFLOW_BASE + i))" "$((SFLOW_BASE + i))" "$i" | sudo tee "$env_file" > /dev/null
        log "  created $env_file"
    fi
done

# ─────────────────────────────────────────────────────────────────
# Install systemd templates and nginx upstream
# ─────────────────────────────────────────────────────────────────
log "installing systemd templates + nginx upstream config"
SYS_USER=$(whoami)
SYS_GROUP=$(id -gn)

sed -e "s|{{SYS_USER}}|$SYS_USER|g" -e "s|{{SYS_GROUP}}|$SYS_GROUP|g" -e "s|{{APP_ROOT}}|$REPO_ROOT|g" \
    "$REPO_ROOT/infra/deploy/systemd/nms_engine@.service.template" | sudo tee /etc/systemd/system/nms_engine@.service > /dev/null

sed -e "s|{{SYS_USER}}|$SYS_USER|g" -e "s|{{SYS_GROUP}}|$SYS_GROUP|g" -e "s|{{APP_ROOT}}|$REPO_ROOT|g" \
    "$REPO_ROOT/infra/deploy/systemd/nms_worker@.service.template" | sudo tee /etc/systemd/system/nms_worker@.service > /dev/null

sudo cp "$REPO_ROOT/infra/deploy/nginx/engine_upstream.conf" /etc/nginx/conf.d/
sudo cp "$REPO_ROOT/infra/deploy/nginx/udp-collectors.conf" /etc/nginx/stream-enabled/
sudo systemctl daemon-reload
sudo nginx -t > /dev/null

log "replacing legacy single-engine unit (if any)"
if sudo systemctl list-unit-files 2>/dev/null | grep -q '^nms_engine.service'; then
    sudo systemctl stop nms_engine.service 2>/dev/null || true
    sudo systemctl disable nms_engine.service 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────
# Install new binary
# ─────────────────────────────────────────────────────────────────
log "backing up current binary (rollback safety)"
[ -f /usr/local/bin/nms_engine ] && sudo cp /usr/local/bin/nms_engine "$PREV_BINARY"

log "installing new binary"
sudo install -m 0755 "$BINARY" /usr/local/bin/nms_engine

# ─────────────────────────────────────────────────────────────────
# Rolling restart: Tier-B Web API cluster (health-checked)
# ─────────────────────────────────────────────────────────────────
log "==> Rolling restart: Tier-B Web API cluster (${WEB_INSTANCES[*]})"
for port in "${WEB_INSTANCES[@]}"; do
    log "  restarting nms_engine@${port}"
    sudo systemctl restart "nms_engine@${port}"
    wait_healthy "$port" || rollback "web instance :${port} failed on new binary"
done

# ─────────────────────────────────────────────────────────────────
# Rolling restart: Tier-A Polling Worker cluster
# No health HTTP check here — workers don't serve web traffic.
# Just verify systemd unit is active.
# ─────────────────────────────────────────────────────────────────
log "==> Rolling restart: Tier-A Polling cluster (${WORKER_INSTANCES[*]})"
for port in "${WORKER_INSTANCES[@]}"; do
    log "  restarting nms_worker@${port}"
    sudo systemctl restart "nms_worker@${port}" || rollback "worker instance :${port} failed to start"
    sleep 3
    if ! sudo systemctl is-active --quiet "nms_worker@${port}"; then
        rollback "worker instance :${port} not active after restart"
    fi
    log "  :${port} active"
done

sleep 2
log "reloading nginx (new upstream config)"
sudo systemctl reload nginx
sleep 2

log "final health check through nginx"
curl -sf -k -A "nms-deploy-healthcheck" https://127.0.0.1/health > /dev/null || rollback "nginx health check failed"

log "verifying UDP collectors are listening"
for port in 514 2055 6343; do
    ss -uln 2>/dev/null | grep -q ":${port} " || rollback "UDP :${port} not listening"
done

log "==> Deploy complete!"
log "    Tier-B Web API cluster  : ${WEB_INSTANCES[*]} (nms_engine@PORT.service) — all Active"
log "    Tier-A Polling cluster  : ${WORKER_INSTANCES[*]} (nms_worker@PORT.service) — 1 Leader + 2 Standby"
