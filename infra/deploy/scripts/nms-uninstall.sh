#!/usr/bin/env bash
# ==============================================================================
# MY_NET NOC — Complete Uninstaller (zero trace left behind)
# Usage: sudo nms-uninstall [--yes] [--dry-run] [--keep-source] [--keep-images] [--remove-images]
# ==============================================================================
set -u

DRY_RUN=0; ASSUME_YES=0; KEEP_SOURCE=0; KEEP_IMAGES=0; REMOVE_IMAGES=0; ROOT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)        ASSUME_YES=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --keep-source)   KEEP_SOURCE=1; shift ;;
        --remove-images) REMOVE_IMAGES=1; shift ;;
        --keep-images)   KEEP_IMAGES=1; shift ;;
        --root)          ROOT_DIR="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "FATAL: run as root"; exit 1; }

# Resolve ROOT_DIR
if [[ -z "$ROOT_DIR" ]] && [[ -f /etc/nms/nms.env ]]; then
    ROOT_DIR="$(grep -E '^NMS_REPO=' /etc/nms/nms.env 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
if [[ -z "$ROOT_DIR" ]]; then
    for cand in /opt/mynet_noc /opt/my_net_noc /root/MY_NET_NOC /home/*/MY_NET_NOC; do
        [[ -d "${cand}/infra/deploy" ]] && { ROOT_DIR="${cand}"; break; }
    done
fi

# Self-execution handling: if script is inside ROOT_DIR, copy to /tmp and re-exec
if [[ -n "${ROOT_DIR:-}" && -d "${ROOT_DIR}" && "$0" == "${ROOT_DIR}"* && "${1:-}" != "--_rerun" ]]; then
    cp "$0" /tmp/nms-uninstall.sh
    chmod +x /tmp/nms-uninstall.sh
    exec /tmp/nms-uninstall.sh --yes --root "$ROOT_DIR" ${KEEP_SOURCE:+--keep-source} ${REMOVE_IMAGES:+--remove-images} ${KEEP_IMAGES:+--keep-images} --_rerun 1
fi

run() { [[ $DRY_RUN -eq 1 ]] && echo "  DRY: $*" || { eval "$@" 2>/dev/null || true; }; }
log() { echo -e "\033[1;34m[uninstall]\033[0m $*"; }

echo "======================================================================"
echo "  MY_NET NOC - COMPLETE UNINSTALLER (zero trace)"
echo "  ROOT_DIR: ${ROOT_DIR:-<unknown>}   DRY_RUN: $DRY_RUN"
echo "======================================================================"

if [[ $ASSUME_YES -ne 1 && $DRY_RUN -ne 1 ]]; then
    read -r -p "This will remove ALL NMS traces. Continue? [y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# 1. Stop & disable services
log "Stopping services..."
run "systemctl stop nms_engine@{8000..8004} nms_worker@{9000..9002} nms_watchdog.timer nms_watchdog.service"
run "systemctl disable nms_engine@{8000..8004} nms_worker@{9000..9002} nms_watchdog.timer nms_watchdog.service"
run "pkill -f nms_engine; pkill -f nms_watchdog"

# 2. Systemd units
log "Removing systemd units..."
run "rm -f /etc/systemd/system/nms_engine@.service /etc/systemd/system/nms_worker@.service"
run "rm -f /etc/systemd/system/nms_watchdog.service /etc/systemd/system/nms_watchdog.timer"
run "rm -rf /etc/systemd/system/nms_engine@.service.d /etc/systemd/system/nms_worker@.service.d"
run "systemctl daemon-reload"

# Docker images removal decision
if [[ $KEEP_IMAGES -eq 0 && $REMOVE_IMAGES -eq 0 && $DRY_RUN -ne 1 ]]; then
    if [[ $ASSUME_YES -eq 1 ]]; then
        REMOVE_IMAGES=1
    else
        read -r -p "Also remove downloaded Docker images (~2GB)? [y/N] " img_ans
        [[ "${img_ans}" =~ ^[Yy]$ ]] && REMOVE_IMAGES=1
    fi
fi

# 3. Docker teardown
if command -v docker >/dev/null 2>&1; then
    log "Tearing down Docker stacks..."
    if [[ -n "$ROOT_DIR" && -d "$ROOT_DIR/infra/deploy/db_cluster" ]]; then
        ( cd "$ROOT_DIR/infra/deploy/db_cluster" && docker compose down -v --remove-orphans 2>/dev/null || true )
    fi
    if [[ -n "$ROOT_DIR" && -d "$ROOT_DIR/infra/deploy/nms_stack" ]]; then
        ( cd "$ROOT_DIR/infra/deploy/nms_stack" && docker compose down -v --remove-orphans 2>/dev/null || true )
    fi
    docker ps -a --format '{{.Names}}' | grep -E 'nms|pgpool|clickhouse|fastnetmon|portainer|gitea|victoria|prometheus|grafana' | xargs -r docker rm -f 2>/dev/null || true
    docker network rm db_cluster_default 2>/dev/null || true
    docker network rm nms_stack_default 2>/dev/null || true
    if [[ $REMOVE_IMAGES -eq 1 ]]; then
        docker image prune -af 2>/dev/null || true
    else
        docker image prune -f 2>/dev/null || true
    fi
    docker volume prune -f 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
fi

# 4. Nginx — full removal (setup.sh installed it, so uninstall removes it)
log "Removing nginx (package + configs)..."
if command -v nginx >/dev/null 2>&1; then
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
fi
# Remove our configs
rm -f /etc/nginx/sites-enabled/nms_proxy
rm -f /etc/nginx/sites-available/nms_proxy
rm -f /etc/nginx/waf-rules.conf
rm -f /etc/nginx/nms_security_headers.conf
rm -f /etc/nginx/conf.d/performance.conf
rm -f /etc/nginx/conf.d/engine_upstream.conf
rm -f /etc/nginx/waf-custom-maps.conf
rm -f /etc/nginx/waf-enabled.conf
rm -f /etc/nginx/.htpasswd
rm -f /etc/nginx/ssl/nms_chain.crt /etc/nginx/ssl/nms.key /etc/nginx/ssl/dhparam.pem
# Remove systemd drop-in we added
rm -f /etc/systemd/system/nginx.service.d/10-nms-docker-order.conf
rmdir /etc/systemd/system/nginx.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
# Purge nginx package (setup.sh installed it via apt)
if command -v apt-get >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  DRY: apt-get purge -y nginx nginx-common"
    else
        apt-get purge -y nginx nginx-common 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi
fi

# 5. /etc/nms (all secrets + state)
log "Removing /etc/nms..."
rm -rf /etc/nms

# 6. Sudoers + sysctl
log "Removing sudoers & sysctl..."
rm -f /etc/sudoers.d/nms-secrets /etc/sudoers.d/nms-update
rm -f /etc/sysctl.d/99-nms*.conf
sysctl --system >/dev/null 2>&1 || true

# 7. /usr/local/bin artifacts (ALL including symlinks)
log "Removing /usr/local/bin artifacts..."
for f in nms_engine telegram-relay rcli nms-admin-reset nms_engine_ready.sh \
         verify-ha.sh nms_watchdog.sh zero-downtime-deploy.sh ha_daily_check.sh \
         apply_nginx.sh nms-update.sh verify-install.sh render-envs.sh \
         apply_secrets.sh apply_redis_auth.sh nms-secrets.sh nms-secrets \
         nms-full-backup.sh nms-full-restore.sh nms-uninstall.sh; do
    rm -f /usr/local/bin/${f}
done
rm -f /usr/local/bin/nms /usr/local/bin/nms-update /usr/local/bin/nms-upgrade /usr/local/bin/nms-uninstall
# Safety net: catch any leftover nms* symlinks/binaries
rm -f /usr/local/bin/nms*
rm -rf /usr/local/bin/static

# 8. Logs/backups/state/temp/cloudflared/cron
log "Removing logs/backups/state..."
rm -rf /var/backups/nms /var/lib/nms
rm -f /var/log/nms*
rm -rf /tmp/nms*
rm -rf /etc/cloudflared /var/lib/cloudflared
grep -rl 'nms' /etc/cron.d /etc/cron.daily /etc/cron.hourly 2>/dev/null | xargs -r sed -i '/nms/d' 2>/dev/null || true

# 9. Project data dir + sentinel runtime + rendered secrets
if [[ -n "${ROOT_DIR:-}" ]]; then
    rm -rf "${ROOT_DIR}/data"
    rm -rf "${ROOT_DIR}/infra/deploy/nms_stack/sentinel"/s*
    rm -rf "${ROOT_DIR}/infra/deploy/nms_stack/rendered"
fi

# 10. Source tree removal (default: remove unless --keep-source)
if [[ $KEEP_SOURCE -eq 0 ]] && [[ -n "${ROOT_DIR:-}" && -d "${ROOT_DIR}" ]]; then
    if [[ "$0" == "${ROOT_DIR}"* ]]; then
        # Auto-copy to /tmp and re-exec to avoid self-deletion
        cp "$0" /tmp/nms-uninstall.sh
        chmod +x /tmp/nms-uninstall.sh
        exec /tmp/nms-uninstall.sh --yes --root "$ROOT_DIR" --_rerun 1
    fi
    log "Removing source tree $ROOT_DIR..."
    rm -rf "$ROOT_DIR"
fi

# 11. Final verification
log "Final verification..."
if [[ $DRY_RUN -eq 0 ]]; then
    echo "  /etc/nms exists?          : $([[ -e /etc/nms ]] && echo YES || echo no)"
    echo "  nms_engine binary?        : $([[ -x /usr/local/bin/nms_engine ]] && echo YES || echo no)"
    echo "  systemd nms_engine?       : $(systemctl is-enabled nms_engine@8000 2>/dev/null || echo no)"
    echo "  leftover nms containers?  : $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c nms || echo 0)"
    echo "  sudoers nms files?        : $(ls /etc/sudoers.d/nms-* 2>/dev/null | wc -l)"
    echo "  nms processes running?    : $(pgrep -c -f nms_engine || echo 0)"
    echo "  nginx nms_proxy exists?   : $([[ -e /etc/nginx/sites-enabled/nms_proxy ]] && echo YES || echo no)"
    echo "  waf-rules.conf exists?    : $([[ -e /etc/nginx/waf-rules.conf ]] && echo YES || echo no)"
    echo "  nms-upgrade binary?       : $([[ -e /usr/local/bin/nms-upgrade ]] && echo YES || echo no)"
    echo "  source tree exists?       : $([[ -n "${ROOT_DIR:-}" && -d "${ROOT_DIR}" ]] && echo YES || echo no)"
fi

echo "======================================================================"
echo "  Uninstall complete. Reboot recommended."
echo "======================================================================"
