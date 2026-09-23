#!/usr/bin/env bash
# bootstrap.sh — first-time setup of the NMS Split-Role HA stack on a NEW server.
#
# Architecture:
#   Tier-A (Polling Cluster): 3 instances on :9000, :9001, :9002
#     → flags: --poller --bgp --syslog --netflow
#     → leader election among themselves via NMS_LEADER_KEY=nms:leader:poller
#
#   Tier-B (Web API Cluster): 5 instances on :8000, :8001, :8002, :8003, :8004
#     → flags: --api
#     → Active-Active load balanced via Nginx least_conn
#     → No background polling or scheduling
#
# Run from a checked-out repo:  sudo bash infra/deploy/scripts/bootstrap.sh
# The repo path is detected automatically; override with NMS_REPO env var.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${NMS_REPO:-}"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# Tier-B: Web API cluster instances
WEB_INSTANCES=(8000 8001 8002 8003 8004)
# Tier-A: Polling worker cluster instances
WORKER_INSTANCES=(9000 9001 9002)

WEB_ENV_DIR=/etc/nms/instances
WORKER_ENV_DIR=/etc/nms/workers

echo "==> Bootstrap NMS Split-Role HA stack from $REPO_ROOT"

if [ ! -d "$REPO_ROOT/backend" ] || [ ! -f "$REPO_ROOT/infra/deploy/nginx/nms_proxy.template" ]; then
    echo "ERROR: $REPO_ROOT does not look like the NMS repo (missing backend/ or infra/deploy/nginx/nms_proxy.template)."
    exit 1
fi

echo "==> Recording repo path (/etc/nms/nms.env)"
sudo mkdir -p /etc/nms
if [ -r /etc/nms/nms.env ] && grep -q '^NMS_REPO=' /etc/nms/nms.env; then
    echo "  NMS_REPO already set in /etc/nms/nms.env (leaving as-is)"
elif [ -r /etc/nms/nms.env ]; then
    echo "NMS_REPO=$REPO_ROOT" | sudo tee -a /etc/nms/nms.env > /dev/null
else
    echo "NMS_REPO=$REPO_ROOT" | sudo tee /etc/nms/nms.env > /dev/null
fi

echo "==> Installing helper scripts to /usr/local/bin"
for s in verify-ha.sh nms_watchdog.sh zero-downtime-deploy.sh ha_daily_check.sh engine-ready.sh; do
    sudo install -m 0755 "$SCRIPT_DIR/$s" "/usr/local/bin/$s"
done
sudo install -m 0755 "$SCRIPT_DIR/engine-ready.sh" /usr/local/bin/nms_engine_ready.sh

# ─────────────────────────────────────────────────────────────────
# Tier-B: Web API cluster env files
# These instances run --api only. They do NOT participate in the
# polling leader election (NMS_LEADER_KEY isolates them).
# ─────────────────────────────────────────────────────────────────
echo "==> Tier-B: Web API cluster env files (ports ${WEB_INSTANCES[*]})"
sudo mkdir -p "$WEB_ENV_DIR"
for i in "${!WEB_INSTANCES[@]}"; do
    port="${WEB_INSTANCES[$i]}"
    cat <<EOF | sudo tee "$WEB_ENV_DIR/${port}.env" > /dev/null
NMS_LEADER_PRIORITY=999
NMS_LEADER_KEY=nms:leader:web
EOF
    echo "  wrote $WEB_ENV_DIR/${port}.env (web-only, no election)"
done

# ─────────────────────────────────────────────────────────────────
# Tier-A: Polling cluster env files
# These instances run --poller --bgp --syslog --netflow.
# They elect a leader among themselves via nms:leader:poller.
# Lower NMS_LEADER_PRIORITY = higher election priority (9000 is
# preferred leader, 9001 first standby, 9002 second standby).
# ─────────────────────────────────────────────────────────────────
echo "==> Tier-A: Polling worker cluster env files (ports ${WORKER_INSTANCES[*]})"
sudo mkdir -p "$WORKER_ENV_DIR"
SYSLOG_BASE=1514
NETFLOW_BASE=2155
SFLOW_BASE=26343
for i in "${!WORKER_INSTANCES[@]}"; do
    port="${WORKER_INSTANCES[$i]}"
    cat <<EOF | sudo tee "$WORKER_ENV_DIR/${port}.env" > /dev/null
SYSLOG_PORT=$((SYSLOG_BASE + i))
NETFLOW_PORT=$((NETFLOW_BASE + i))
SFLOW_PORT=$((SFLOW_BASE + i))
NMS_LEADER_PRIORITY=$i
NMS_LEADER_KEY=nms:leader:poller
EOF
    echo "  wrote $WORKER_ENV_DIR/${port}.env (priority $i, poller election)"
done

# ─────────────────────────────────────────────────────────────────
# Systemd units
# ─────────────────────────────────────────────────────────────────
echo "==> Installing systemd units"
RUN_USER="${NMS_SERVICE_USER:-${SUDO_USER:-$(id -un)}}"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"

# Web API engine template (--api)
sed -e "s|{{APP_ROOT}}|$REPO_ROOT|g" \
    -e "s|{{SYS_USER}}|$RUN_USER|g" \
    -e "s|{{SYS_GROUP}}|$RUN_GROUP|g" \
    "$REPO_ROOT/infra/deploy/systemd/nms_engine@.service.template" | sudo tee /etc/systemd/system/nms_engine@.service > /dev/null
echo "  installed nms_engine@.service (web api cluster)"

# Polling worker template (--poller --bgp --syslog --netflow)
sed -e "s|{{APP_ROOT}}|$REPO_ROOT|g" \
    -e "s|{{SYS_USER}}|$RUN_USER|g" \
    -e "s|{{SYS_GROUP}}|$RUN_GROUP|g" \
    "$REPO_ROOT/infra/deploy/systemd/nms_worker@.service.template" | sudo tee /etc/systemd/system/nms_worker@.service > /dev/null
echo "  installed nms_worker@.service (polling cluster)"

# Watchdog & backup
sudo cp "$REPO_ROOT/infra/deploy/systemd/nms_watchdog.service" /etc/systemd/system/ 2>/dev/null || true
sudo cp "$REPO_ROOT/infra/deploy/systemd/nms_watchdog.timer" /etc/systemd/system/ 2>/dev/null || true
sudo mkdir -p /etc/systemd/system/nms_engine@.service.d
sed "s|{{APP_ROOT}}|$REPO_ROOT|g" \
    "$REPO_ROOT/infra/deploy/systemd/hardening.conf" | sudo tee /etc/systemd/system/nms_engine@.service.d/hardening.conf > /dev/null
sed -e "s|{{APP_ROOT}}|$REPO_ROOT|g" \
    -e "s|{{SYS_USER}}|$RUN_USER|g" \
    -e "s|{{SYS_GROUP}}|$RUN_GROUP|g" \
    "$REPO_ROOT/infra/deploy/backup/nms_backup.service.template" | sudo tee /etc/systemd/system/nms_backup.service > /dev/null
sudo systemctl daemon-reload

# ─────────────────────────────────────────────────────────────────
# Nginx
# ─────────────────────────────────────────────────────────────────
echo "==> Nginx configs (repo path baked in)"
sudo mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/stream-enabled
sed "s|{{APP_ROOT}}|$REPO_ROOT|g" "$REPO_ROOT/infra/deploy/nginx/nms_proxy.template" \
    | sudo tee /etc/nginx/sites-available/nms_proxy > /dev/null
sudo ln -sf /etc/nginx/sites-available/nms_proxy /etc/nginx/sites-enabled/nms_proxy
sudo cp "$REPO_ROOT/infra/deploy/nginx/engine_upstream.conf" /etc/nginx/conf.d/
sudo cp "$REPO_ROOT/infra/deploy/nginx/udp-collectors.conf" /etc/nginx/stream-enabled/

echo "==> Enabling watchdog services"
sudo systemctl enable nms_watchdog.timer > /dev/null 2>&1 || true
sudo systemctl start nms_watchdog.timer > /dev/null 2>&1 || true

sudo nginx -t
sudo systemctl reload nginx > /dev/null 2>&1 || true

echo
echo "==> Bootstrap complete."
echo "    Tier-B Web API cluster  : ${WEB_INSTANCES[*]} (nms_engine@PORT.service)"
echo "    Tier-A Polling cluster  : ${WORKER_INSTANCES[*]} (nms_worker@PORT.service)"
echo
echo "    Next steps:"
echo "    1. Place the nms_engine binary at /usr/local/bin/nms_engine"
echo "    2. sudo bash infra/deploy/scripts/zero-downtime-deploy.sh /usr/local/bin/nms_engine"
echo "    3. sudo bash /usr/local/bin/verify-ha.sh"
