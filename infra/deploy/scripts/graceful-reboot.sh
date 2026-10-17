#!/bin/bash
# Graceful reboot: suppress pgpool failover_command during planned reboots.
#
# Without this, pgpool's health check sees pg-0 leave during shutdown and fires
# failover_command (phantom promote of the standby). The bitnami entrypoint
# auto-heals on next boot, but a clean reboot avoids the split-brain window.
#
# Sequence:
#   1. stop pgpool   (no health checks -> no failover events during shutdown)
#   2. reboot        (systemd brings the stack back up)
#   3. watchdog      (nms_watchdog.timer) auto-attaches any pgpool backend
#                    node still marked down within ~1 min of boot
set -e

echo "[$(date)] Graceful reboot: clearing pooler node-state, then stopping DB front door + poolers..."
# The node-status file lives in each container's own /tmp (NOT a volume), so it
# must be removed INSIDE the container before it is stopped; otherwise a stale
# "down" entry would survive the container restart after the reboot.
sudo docker exec pg-pgpool   sh -c 'rm -f /tmp/pgpool_status' 2>/dev/null || true
sudo docker exec pg-pgpool-2 sh -c 'rm -f /tmp/pgpool_status' 2>/dev/null || true
sudo docker stop pgpool-proxy 2>/dev/null || true
sudo docker stop pg-pgpool    2>/dev/null || true
sudo docker stop pg-pgpool-2  2>/dev/null || true

echo "[$(date)] Rebooting in 2 seconds..."
(sleep 2; sudo systemctl reboot) >/dev/null 2>&1 &
REPO_ROOT="${NMS_REPO:-}"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "[$(date)] Reboot scheduled. After boot, verify:"
echo "    sudo bash $REPO_ROOT/infra/deploy/scripts/verify-ha.sh"
