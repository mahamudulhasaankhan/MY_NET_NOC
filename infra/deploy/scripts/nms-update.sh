#!/usr/bin/env bash
# ==============================================================================
# MY_NET NOC — Universal Lifecycle & Release Manager
# Commands: nms | nms-update | nms-upgrade
# Usage:
#   sudo nms                 # smart: check version, update or upgrade as needed
#   sudo nms-update          # same as nms
#   sudo nms-upgrade         # force full upgrade (binary + frontend + migrate + restart)
#   sudo nms --check         # only check, do not apply
#   sudo nms --force-update  # force update even if same version
# ==============================================================================
set -u

MODE="smart"          # smart | upgrade | check
FORCE_UPDATE=0
CHECK_ONLY=0
ASSUME_YES=0
LOCKFILE="/var/run/nms-lifecycle.lock"
LOGFILE="/var/log/nms_update.log"
REMOTE_VERSION_URL="https://raw.githubusercontent.com/mahamudulhasaankhan/MY_NET_NOC/main/VERSION"
PUBLIC_REPO="https://github.com/mahamudulhasaankhan/MY_NET_NOC.git"

case "$(basename "$0")" in
    nms-upgrade) MODE="upgrade" ;;
    nms-update)   MODE="update"  ;;
    nms|nms-lifecycle.sh) MODE="smart" ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upgrade)      MODE="upgrade"; shift ;;
        --check)        CHECK_ONLY=1; shift ;;
        --force-update) FORCE_UPDATE=1; shift ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        --help|-h)      echo "Usage: nms [--check|--upgrade|--force-update]"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Colors
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "$*" | tee -a "$LOGFILE"; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "FATAL: must run as root (sudo nms)" >&2
    exit 1
fi

# ── Lock (prevent concurrent runs) ────────────────────────────────────────────
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Another nms update is already running. Exiting." >&2
    exit 1
fi

mkdir -p "$(dirname "$LOGFILE")"
echo "===== nms lifecycle run $(date) =====" >> "$LOGFILE"

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN} 🔄 MY_NET Enterprise NOC — Lifecycle Manager${NC}"
echo -e " Lead Architect: Md. Mahamudul Hassan Khan"
echo -e "${BLUE}======================================================================${NC}"

# ── Resolve INSTALL_DIR ────────────────────────────────────────────────────────
INSTALL_DIR=""
if [[ -f /etc/nms/nms.env ]]; then
    INSTALL_DIR="$(grep -E '^NMS_REPO=' /etc/nms/nms.env 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
if [[ -z "$INSTALL_DIR" ]] && [[ -f /etc/systemd/system/nms_engine@.service ]]; then
    INSTALL_DIR="$(grep '^WorkingDirectory=' /etc/systemd/system/nms_engine@.service 2>/dev/null | cut -d= -f2 || true)"
fi
if [[ -z "$INSTALL_DIR" || ! -d "$INSTALL_DIR" ]]; then
    for cand in /opt/mynet_noc /opt/my_net_noc /root/MY_NET_NOC /home/*/MY_NET_NOC; do
        [[ -d "${cand}/infra/deploy" ]] && { INSTALL_DIR="${cand}"; break; }
    done
fi
if [[ -z "$INSTALL_DIR" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "${SCRIPT_DIR}/../../frontend" ]]; then
        INSTALL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    elif [[ -d "${PWD}/frontend" ]]; then
        INSTALL_DIR="${PWD}"
    fi
fi

if [[ -z "$INSTALL_DIR" || ! -d "$INSTALL_DIR" ]]; then
    echo -e "${RED}FATAL: could not locate installation directory.${NC}" >&2
    exit 1
fi
echo -e "📂 Installation Directory: ${YELLOW}${INSTALL_DIR}${NC}"

# Load central store
if [[ -r /etc/nms/nms.env ]]; then
    set -a; . /etc/nms/nms.env; set +a
fi

# Local version
LOCAL_VERSION="$(tr -d '[:space:]' < "${INSTALL_DIR}/VERSION" 2>/dev/null || echo unknown)"
LOCAL_VERSION="${LOCAL_VERSION:-unknown}"

echo -e "📌 Local version: ${YELLOW}${LOCAL_VERSION}${NC}"

# Fetch remote version
REMOTE_VERSION=""
if command -v curl >/dev/null 2>&1; then
    REMOTE_VERSION="$(curl -fsSL --max-time 15 "$REMOTE_VERSION_URL" 2>/dev/null | tr -d '[:space:]')"
fi
if [[ -z "$REMOTE_VERSION" ]]; then
    echo -e "${YELLOW}⚠️  Could not fetch remote version (offline?). Proceeding with local only.${NC}"
    REMOTE_VERSION="$LOCAL_VERSION"
fi
echo -e "📌 Remote version: ${YELLOW}${REMOTE_VERSION}${NC}"

if [[ "$MODE" == "smart" ]]; then
    if [[ "$REMOTE_VERSION" == "$LOCAL_VERSION" ]]; then
        if [[ -d "${INSTALL_DIR}/.git" ]]; then
            GIT_TERMINAL_PROMPT=0 git -C "$INSTALL_DIR" fetch origin main --quiet 2>/dev/null || true
            LOCAL_HEAD="$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || echo '')"
            REMOTE_HEAD="$(git -C "$INSTALL_DIR" rev-parse origin/main 2>/dev/null || echo '')"
            if [[ -n "$LOCAL_HEAD" && "$LOCAL_HEAD" != "$REMOTE_HEAD" && -n "$REMOTE_HEAD" ]]; then
                AVAILABLE="update"
                echo -e "${YELLOW}Update available (same version ${LOCAL_VERSION}, new commits)${NC}"
            else
                AVAILABLE="none"
                echo -e "${GREEN}Already up to date (${LOCAL_VERSION}).${NC}"
            fi
        else
            AVAILABLE="none"
            echo -e "${GREEN}Already up to date (${LOCAL_VERSION}).${NC}"
        fi
    else
        AVAILABLE="upgrade"
        echo -e "${YELLOW}Upgrade available: ${LOCAL_VERSION} -> ${REMOTE_VERSION}${NC}"
    fi
    if [[ "$AVAILABLE" == "none" ]]; then
        if [[ $FORCE_UPDATE -eq 1 ]]; then
            AVAILABLE="update"
            echo -e "${YELLOW}--force-update: proceeding with update.${NC}"
        else
            exit 0
        fi
    fi
    if [[ $CHECK_ONLY -eq 1 ]]; then
        echo "Check complete. Available: $AVAILABLE"
        exit 0
    fi
    if [[ $ASSUME_YES -eq 0 && -t 0 ]]; then
        read -r -p "Apply ${AVAILABLE}? [y/N] " ans
        [[ "${ans}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi
    MODE="$AVAILABLE"
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
    echo "Check complete. Mode would be: $MODE"
    exit 0
fi


# ── UPDATE mode (minor changes, no restart) ────────────────────────────────────
if [[ "$MODE" == "update" ]]; then
    log "${BLUE}📥 [UPDATE] Fetching latest...${NC}"
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
GIT_TERMINAL_PROMPT=0         git -C "$INSTALL_DIR" fetch origin main --quiet 2>/dev/null || true
        git -C "$INSTALL_DIR" reset --hard origin/main 2>/dev/null || git -C "$INSTALL_DIR" pull 2>/dev/null || true
    else
        TMPD=$(mktemp -d)
        git clone --depth 1 "$PUBLIC_REPO" "$TMPD" 2>/dev/null && \
            cp -r "$TMPD"/* "$INSTALL_DIR"/ 2>/dev/null || true
        rm -rf "$TMPD"
    fi

    log "${BLUE}⚙️  [UPDATE] Syncing helper scripts, frontend, nginx config...${NC}"
    # Helper scripts
    for script in ${INSTALL_DIR}/infra/deploy/scripts/*.sh; do
        [[ -f "$script" ]] || continue
        bn=$(basename "$script")
        install -m 755 "$script" "/usr/local/bin/${bn}" 2>/dev/null || true
    done
    # Symlinks
    ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms-update 2>/dev/null || true
    ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms 2>/dev/null || true
    ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms-upgrade 2>/dev/null || true

    # Frontend sync
    if [[ -d "${INSTALL_DIR}/frontend/dist" ]]; then
        mkdir -p /usr/local/bin/static/dist
        rsync -a --delete "${INSTALL_DIR}/frontend/dist/" /usr/local/bin/static/dist/ 2>/dev/null || true
        chmod 755 /usr/local/bin/static /usr/local/bin/static/dist 2>/dev/null || true
    fi

    # Nginx + WAF
    if [[ -x /usr/local/bin/apply_nginx.sh ]]; then
        /usr/local/bin/apply_nginx.sh 2>/dev/null || true
    fi
    nginx -t 2>/dev/null && (systemctl is-active --quiet nginx && systemctl reload nginx || systemctl restart nginx) 2>/dev/null || true

    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN} ✅ UPDATE complete (no restart, zero disruption).${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    exit 0
fi

# ── UPGRADE mode (full upgrade with restart) ──────────────────────────────────
log "${BLUE}⬆️  [UPGRADE] Starting full upgrade to ${REMOTE_VERSION}...${NC}"

# Safety backup
UPGRADE_BACKUP_DIR="/var/backups/nms"
mkdir -p "$UPGRADE_BACKUP_DIR"
if [[ -f /etc/nms/nms.env ]]; then
    set -a; . /etc/nms/nms.env; set +a
fi
BACKUP_FILE="${UPGRADE_BACKUP_DIR}/pre_upgrade_$(date +%Y%m%d_%H%M%S).dump"
if [[ -n "${MIGRATION_DATABASE_URL:-${DATABASE_URL:-}}" ]] && command -v pg_dump >/dev/null 2>&1; then
    if pg_dump "${MIGRATION_DATABASE_URL:-$DATABASE_URL}" -Fc -f "$BACKUP_FILE" 2>/dev/null; then
        log "${GREEN}   ✅ Safety backup: ${BACKUP_FILE}${NC}"
        ls -1t "${UPGRADE_BACKUP_DIR}"/pre_upgrade_*.dump 2>/dev/null | tail -n +11 | xargs -r rm -f
    else
        log "${YELLOW}   ⚠️  Backup failed — proceeding (no rollback point).${NC}"
        rm -f "$BACKUP_FILE"
    fi
else
    log "${YELLOW}   ⚠️  pg_dump/DATABASE_URL unavailable — skipping backup.${NC}"
fi

# Rollback helper
rollback() {
    local reason="$1"
    log "${RED}ROLLBACK ($reason): restoring previous binary${NC}"
    if [[ -f /tmp/nms_engine.prev ]]; then
        install -m 0755 /tmp/nms_engine.prev /usr/local/bin/nms_engine
    fi
    for port in 8000 8001 8002 8003 8004; do
        systemctl restart "nms_engine@${port}" 2>/dev/null || true
    done
    for port in 9000 9001 9002; do
        systemctl restart "nms_worker@${port}" 2>/dev/null || true
    done
    systemctl reload nginx 2>/dev/null || true
    log "${RED}ROLLBACK complete — previous version restored${NC}"
    exit 1
}

# Git pull / clone
cp /usr/local/bin/nms_engine /tmp/nms_engine.prev 2>/dev/null || true
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    log "${BLUE}📥 [1/6] Fetching latest from GitHub...${NC}"
GIT_TERMINAL_PROMPT=0     git -C "$INSTALL_DIR" fetch origin main --quiet 2>/dev/null || true
    git -C "$INSTALL_DIR" reset --hard origin/main 2>/dev/null || git -C "$INSTALL_DIR" pull 2>/dev/null || true
else
    log "${BLUE}📥 [1/6] Downloading latest release bundle...${NC}"
    TMPD=$(mktemp -d)
    if git clone --depth 1 "$PUBLIC_REPO" "$TMPD" 2>/dev/null; then
        cp -r "$TMPD"/* "$INSTALL_DIR"/ 2>/dev/null || true
    else
        log "${RED}FATAL: could not fetch from GitHub.${NC}"
        exit 1
    fi
    rm -rf "$TMPD"
fi

# Binary copy
log "${BLUE}⚙️  [2/6] Updating engine binaries...${NC}"
if [[ -f "${INSTALL_DIR}/bin/nms_engine" ]]; then
    install -m 755 "${INSTALL_DIR}/bin/nms_engine" /usr/local/bin/nms_engine || rollback "binary install failed"
else
    log "${YELLOW}⚠️  No pre-built binary in bundle — skipping (source mode).${NC}"
fi
for b in telegram-relay rcli nms-admin-reset; do
    [[ -f "${INSTALL_DIR}/bin/$b" ]] && { install -m 755 "${INSTALL_DIR}/bin/$b" "/usr/local/bin/$b" 2>/dev/null || true; }
done
[[ -f /usr/local/bin/nms-admin-reset ]] && chmod 700 /usr/local/bin/nms-admin-reset

# Helper scripts
log "${BLUE}🔧 [3/6] Syncing helper scripts...${NC}"
for script in "${INSTALL_DIR}/infra/deploy/scripts/"*.sh; do
    [[ -f "$script" ]] || continue
    bn=$(basename "$script")
    install -m 755 "$script" "/usr/local/bin/${bn}" 2>/dev/null || true
done
ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms-update 2>/dev/null || true
ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms 2>/dev/null || true
ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms-upgrade 2>/dev/null || true

# Frontend sync
log "${BLUE}⚛️  [4/6] Syncing frontend...${NC}"
if [[ -d "${INSTALL_DIR}/frontend/dist" ]]; then
    mkdir -p /usr/local/bin/static/dist
    rsync -a --delete "${INSTALL_DIR}/frontend/dist/" /usr/local/bin/static/dist/ 2>/dev/null || true
    chmod 755 /usr/local/bin/static /usr/local/bin/static/dist 2>/dev/null || true
fi

# Nginx + WAF
log "${BLUE}🔒 [5/6] Updating nginx config & WAF rules...${NC}"
if [[ -x /usr/local/bin/apply_nginx.sh ]]; then
    /usr/local/bin/apply_nginx.sh 2>/dev/null || echo "${YELLOW}⚠️  apply_nginx had warnings${NC}"
fi
nginx -t 2>/dev/null && (systemctl is-active --quiet nginx && systemctl reload nginx || systemctl restart nginx) 2>/dev/null || true

# DB migrations
log "${BLUE}🗄️  [6/6] Applying DB migrations...${NC}"
if [[ -x /usr/local/bin/nms_engine && -r /etc/nms/nms.env ]]; then
    set -a; . /etc/nms/nms.env; set +a
    if ! /usr/local/bin/nms_engine --migrate 2>&1 | tail -3; then
        rollback "migration failed"
    fi
fi


# ── Rolling restart (zero-downtime) ────────────────────────────────────────────
echo -e "${BLUE}🔄 Performing zero-downtime rolling restart of 8 engine nodes...${NC}"
WEB_INSTANCES=(8000 8001 8002 8003 8004)
WORKER_INSTANCES=(9000 9001 9002)

for port in "${WEB_INSTANCES[@]}"; do
    systemctl restart "nms_engine@${port}" 2>/dev/null || true
    sleep 0.2
done
for port in "${WORKER_INSTANCES[@]}"; do
    systemctl restart "nms_worker@${port}" 2>/dev/null || true
    sleep 0.2
done
systemctl reload nginx 2>/dev/null || true

# ── Health check ──────────────────────────────────────────────────────────────
echo -e "${BLUE}🔍 Verifying cluster health...${NC}"
sleep 2
HEALTH_PASS=0
for port in "${WEB_INSTANCES[@]}"; do
    if curl -sf --max-time 3 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
        ((HEALTH_PASS++)) || true
    fi
done

# ── Report ────────────────────────────────────────────────────────────────────
NEW_VERSION="$(tr -d '[:space:]' < "${INSTALL_DIR}/VERSION" 2>/dev/null || echo unknown)"
echo ""
echo -e "${GREEN}======================================================================${NC}"
if [[ "$HEALTH_PASS" -eq "${#WEB_INSTANCES[@]}" ]]; then
    echo -e "${GREEN} ✅ MY_NET NOC Successfully Upgraded: ${LOCAL_VERSION} → ${NEW_VERSION}${NC}"
    echo -e " ⚡ Status: ${HEALTH_PASS}/${#WEB_INSTANCES[@]} Web Nodes Healthy & Serving Traffic."
else
    echo -e "${YELLOW} ⚠️  Upgrade applied but only ${HEALTH_PASS}/${#WEB_INSTANCES[@]} nodes healthy.${NC}"
    echo -e "   Check: systemctl status nms_engine@8000"
fi
echo -e "${GREEN}======================================================================${NC}"

# ── Telegram notification (if configured) ─────────────────────────────────────
if [[ -r /etc/nms/nms.env ]]; then
    set -a; . /etc/nms/nms.env; set +a
    if [[ -n "${TELEGRAM_TOKEN:-}" && -n "${TELEGRAM_CHAT:-}" ]]; then
        curl -s -m 10 -F "chat_id=${TELEGRAM_CHAT}" \
            -F "text=✅ NMS upgraded: ${LOCAL_VERSION} → ${NEW_VERSION} (${HEALTH_PASS}/${#WEB_INSTANCES[@]} nodes healthy)" \
            "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" >/dev/null 2>&1 || true
    fi
fi

exit 0
