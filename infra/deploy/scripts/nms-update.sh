#!/usr/bin/env bash
# ==============================================================================
# MY_NET Enterprise NOC — Self-Update Utility
# Author: Md. Mahamudul Hassan Khan (https://www.linkedin.com/in/md-mahamudul-hassan-khan/)
# License: GNU AGPLv3
# ==============================================================================
set -euo pipefail

# Ensure root privileges
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN} 🔄 MY_NET Enterprise NOC — Auto-Updater${NC}"
echo -e " Lead Architect: Md. Mahamudul Hassan Khan"
echo -e "${BLUE}======================================================================${NC}"

# Find installation directory
INSTALL_DIR=""
if [ -d "/etc/nms" ] && [ -f "/etc/nms/nms.env" ]; then
    # Try finding repository directory from systemd service definition
    if [ -f "/etc/systemd/system/nms_engine@.service" ]; then
        SERVICE_WORK_DIR=$(grep "^WorkingDirectory=" /etc/systemd/system/nms_engine@.service 2>/dev/null | cut -d= -f2 || true)
        if [ -n "$SERVICE_WORK_DIR" ] && [ -d "$SERVICE_WORK_DIR" ]; then
            INSTALL_DIR="$SERVICE_WORK_DIR"
        fi
    fi
fi

if [ -z "$INSTALL_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -d "${SCRIPT_DIR}/../../frontend" ]; then
        INSTALL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    elif [ -d "/opt/mynet_noc" ]; then
        INSTALL_DIR="/opt/mynet_noc"
    elif [ -d "${PWD}/frontend" ]; then
        INSTALL_DIR="${PWD}"
    fi
fi

echo -e "📂 Detected Installation Directory: ${YELLOW}${INSTALL_DIR:-/tmp/mynet_noc_update}${NC}"

# If install directory is a git repository, pull latest
if [ -n "$INSTALL_DIR" ] && [ -d "${INSTALL_DIR}/.git" ]; then
    echo -e "${BLUE}📥 [1/4] Fetching latest updates from GitHub...${NC}"
    cd "${INSTALL_DIR}"
    git fetch origin main || git fetch origin master || true
    git reset --hard origin/main || git pull || true
else
    echo -e "${BLUE}📥 [1/4] Downloading latest production release bundle...${NC}"
    TMP_DIR=$(mktemp -d /tmp/mynet_update.XXXXXX)
    git clone --depth 1 https://github.com/mahamudulhasaankhan/MY_NET_NOC.git "${TMP_DIR}"
    
    if [ -z "$INSTALL_DIR" ]; then
        INSTALL_DIR="/opt/mynet_noc"
        mkdir -p "${INSTALL_DIR}"
    fi
    
    cp -r "${TMP_DIR}/bin" "${INSTALL_DIR}/" 2>/dev/null || true
    cp -r "${TMP_DIR}/frontend" "${INSTALL_DIR}/" 2>/dev/null || true
    cp -r "${TMP_DIR}/infra" "${INSTALL_DIR}/" 2>/dev/null || true
    cp -r "${TMP_DIR}/setup.sh" "${INSTALL_DIR}/" 2>/dev/null || true
    rm -rf "${TMP_DIR}"
fi

echo -e "${BLUE}⚙️ [2/4] Updating engine binaries and applying pre-flight migrations...${NC}"
if [ -f "${INSTALL_DIR}/bin/nms_engine" ]; then
    cp -f "${INSTALL_DIR}/bin/nms_engine" /usr/local/bin/nms_engine
    chmod +x /usr/local/bin/nms_engine
fi
if [ -f "${INSTALL_DIR}/bin/telegram-relay" ]; then
    cp -f "${INSTALL_DIR}/bin/telegram-relay" /usr/local/bin/telegram-relay 2>/dev/null || true
    chmod +x /usr/local/bin/telegram-relay 2>/dev/null || true
fi
if [ -f "${INSTALL_DIR}/bin/rcli" ]; then
    cp -f "${INSTALL_DIR}/bin/rcli" /usr/local/bin/rcli 2>/dev/null || true
    chmod +x /usr/local/bin/rcli 2>/dev/null || true
fi

# Run pre-flight migrations
/usr/local/bin/nms_engine --migrate || true

echo -e "${BLUE}🔄 [3/4] Performing zero-downtime rolling restart of 8 engine nodes...${NC}"
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

echo -e "${BLUE}🔍 [4/4] Verifying cluster health...${NC}"
sleep 1
HEALTH_PASS=0
for port in "${WEB_INSTANCES[@]}"; do
    if curl -sf --max-time 2 "http://127.0.0.1:${port}/api/v2/health" >/dev/null 2>&1; then
        ((HEALTH_PASS++)) || true
    fi
done

echo ""
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN} ✅ MY_NET NOC Successfully Upgraded to Latest Version!${NC}"
echo -e " ⚡ Status: ${HEALTH_PASS}/${#WEB_INSTANCES[@]} Web Nodes Healthy & Serving Traffic."
echo -e "${GREEN}======================================================================${NC}"
