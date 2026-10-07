#!/usr/bin/env bash
# ==============================================================================
# MY_NET NOC — 1-Click Master Developer & Production Server Provisioner
# Author: Md. Mahamudul Hassan Khan (https://www.linkedin.com/in/md-mahamudul-hassan-khan/)
# Copyright (c) 2026 Md. Mahamudul Hassan Khan. All rights reserved.
# ==============================================================================
set -euo pipefail

TLS_CERT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --regen-pin)
            P1="$(openssl rand -hex 2 | tr 'a-f' 'A-F')"
            P2="$(openssl rand -hex 2 | tr 'a-f' 'A-F')"
            SETUP_PIN="${P1}-${P2}"
            printf "%s" "$SETUP_PIN" | sha256sum | awk '{print $1}' > /etc/nms/.setup-pin-hash
            chmod 600 /etc/nms/.setup-pin-hash
            echo ""
            echo "NEW SETUP PIN (valid 60 min): $SETUP_PIN"
            echo "Enter it at https://<server-ip>/setup within the hour."
            exit 0
            ;;
        --tls-cert)
            TLS_CERT_DIR="${2:-}"
            shift 2
            ;;
        *) shift ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'

# ── First-Run Setup Wizard PIN ────────────────────────────────────────────
# One-time PIN gates the web wizard (/setup). Only its SHA256 is stored;
# the plaintext below is printed ONCE here and never persisted.
if [ ! -f /etc/nms/.initialized ]; then
    P1="$(openssl rand -hex 2 | tr 'a-f' 'A-F')"
    P2="$(openssl rand -hex 2 | tr 'a-f' 'A-F')"
    SETUP_PIN="${P1}-${P2}"
    printf "%s" "$SETUP_PIN" | sha256sum | awk '{print $1}' > /etc/nms/.setup-pin-hash
    chmod 600 /etc/nms/.setup-pin-hash
fi
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "======================================================================"
echo "  __  ____   __  _   _ _____ _____   _   _  ___   ____ "
echo " |  \/  \ \ / / | \ | | ____|_   _| | \ | |/ _ \ / ___|"
echo " | |\/| |\ V /  |  \| |  _|   | |   |  \| | | | | |    "
echo " | |  | | | |   | |\  | |___  | |   | |\  | |_| | |___ "
echo " |_|  |_| |_|   |_| \_|_____| |_|   |_| \_|\___/ \____|"
echo ""
echo " 🌐 MY_NET Enterprise NOC — 1-Click Master Provisioner"
echo " Architect: Md. Mahamudul Hassan Khan"
echo " LinkedIn : https://www.linkedin.com/in/md-mahamudul-hassan-khan/"
echo "======================================================================"
echo -e "${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This installer must be run with root privileges. Please run: sudo bash setup.sh${NC}"
   exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES=(8000 8001 8002 8003 8004)
WEB_INSTANCES=(8000 8001 8002 8003 8004)
WORKER_INSTANCES=(9000 9001 9002)
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "${RUN_USER}" 2>/dev/null || echo "${RUN_USER}")"

# ── BINARY vs SOURCE mode ─────────────────────────────────────────────────
# Public-repo installs ship pre-built binaries: bin/nms_engine + frontend/dist.
# In that mode the Go/Node toolchains are NEVER installed or needed.
BINARY_MODE=false
if [[ -f "${ROOT_DIR}/bin/nms_engine" && -d "${ROOT_DIR}/frontend/dist" ]]; then
    BINARY_MODE=true
    echo -e "${CYAN}📦 Pre-built distribution detected → BINARY install mode (no compilers)${NC}"
fi

# Step 1: Install System Dependencies & Toolchains
echo -e "${YELLOW}📦 [1/9] Verifying & Installing OS Packages (nginx, curl, jq, openssl, rsync, git)...${NC}"
apt-get update -qq && apt-get install -y -qq \
    nginx curl jq openssl rsync git build-essential \
    ca-certificates gnupg lsb-release

# Step 2: Ensure Docker Engine & Compose
echo -e "${YELLOW}🐳 [2/9] Checking Docker & Docker Compose...${NC}"
if ! command -v docker &>/dev/null; then
    echo "  -> Installing Docker Engine..."
    curl -fsSL https://get.docker.com | sh
fi

# Step 3: Ensure Go toolchain (SOURCE mode only)
echo -e "${YELLOW}⚙️ [3/9] Checking Go compiler toolchain...${NC}"
if [[ "$BINARY_MODE" == "true" ]]; then
    echo "   ↳ skipped (binary mode)"
elif ! command -v go &>/dev/null; then
    echo "  -> Installing Go 1.24..."
    GO_TAR="go1.24.0.linux-amd64.tar.gz"
    curl -fsSL "https://go.dev/dl/${GO_TAR}" -o "/tmp/${GO_TAR}"
    rm -rf /usr/local/go && tar -C /usr/local -xzf "/tmp/${GO_TAR}"
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    rm -f "/tmp/${GO_TAR}"
fi

# Step 4: Ensure Node.js & npm
echo -e "${YELLOW}🎨 [4/9] Checking Node.js environment...${NC}"
if [[ "$BINARY_MODE" == "true" ]]; then
    echo "   ↳ skipped (binary mode)"
elif ! command -v npm &>/dev/null; then
    echo "  -> Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
fi

# Step 5: Install Go Engine binary (pre-built in BINARY mode, compiled in SOURCE mode)
if [[ "$BINARY_MODE" == "true" ]]; then
    echo -e "${YELLOW}🔨 [5/9] Installing pre-built Engine binary…${NC}"
    cp "${ROOT_DIR}/bin/nms_engine" /usr/local/bin/nms_engine
else
    echo -e "${YELLOW}🔨 [5/9] Compiling Go Engine binary from source…${NC}"
    cd "${ROOT_DIR}/backend"
    CGO_ENABLED=0 go build -ldflags="-s -w -X 'nms_engine/internal/brand.Version=${VERSION:-1.0.0}'" -o nms_engine ./cmd/nms_engine
    cp nms_engine /usr/local/bin/nms_engine
fi
chmod +x /usr/local/bin/nms_engine

# Companion binaries (relay/rcli) if shipped; break-glass tool ships 0700
for b in telegram-relay rcli nms-admin-reset; do
    [[ -f "${ROOT_DIR}/bin/$b" ]] && { cp "${ROOT_DIR}/bin/$b" /usr/local/bin/; chmod +x "/usr/local/bin/$b"; }
done
[[ -f /usr/local/bin/nms-admin-reset ]] && chmod 700 /usr/local/bin/nms-admin-reset
mkdir -p /usr/local/bin/static
echo "   ✅ Engine binary installed to /usr/local/bin/nms_engine"

# Step 6: Frontend bundle (pre-built dist in BINARY mode)
if [[ "$BINARY_MODE" == "true" ]]; then
    echo -e "${YELLOW}⚛️ [6/9] Installing pre-built Frontend bundle…${NC}"
else
    echo -e "${YELLOW}⚛️ [6/9] Building React Frontend SPA…${NC}"
    cd "${ROOT_DIR}/frontend"
    [[ -d "node_modules" ]] || { npm ci --prefer-offline 2>/dev/null || npm install; }
    npm run build
fi
mkdir -p /usr/local/bin/static/dist "${ROOT_DIR}/uploads"
rsync -a --delete "${ROOT_DIR}/frontend/dist/" /usr/local/bin/static/dist/
echo "   ✅ Frontend deployed to /usr/local/bin/static/dist (+ uploads dir ready)"

# Step 7: Deploy Environment Configurations & Helper Scripts
echo -e "${YELLOW}🔧 [7/9] Configuring environment, secrets, and helper scripts...${NC}"
mkdir -p /etc/nms/instances /etc/nms/workers

if [[ ! -f /etc/nms/nms.env ]]; then
    # ── ZERO-STATIC-PASSWORD FRESH INSTALL ────────────────────────────────
    # Every credential is generated right here, written ONLY to the central
    # store (0600 root:root), and derived env files are rendered from it by
    # render-envs.sh. Nothing is printed, committed, or shipped in the repo.
    enc_key="$(openssl rand -hex 16)"
    secret_key="$(openssl rand -hex 16)"
    db_pass="$(openssl rand -hex 16)"
    db_repl_pass="$(openssl rand -hex 16)"
    db_postgres_pass="$(openssl rand -hex 16)"
    pgpool_pcp_pass="$(openssl rand -hex 16)"
    redis_pass="$(openssl rand -hex 16)"
    nats_token="$(openssl rand -hex 24)"
    ch_pass="$(openssl rand -hex 16)"
    grafana_ch_pass="$(openssl rand -hex 16)"
    radius_secret="$(openssl rand -hex 16)"
    dbgate_pass="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    backup_pass="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    # PostgreSQL/Redis/NATS/ClickHouse are published on 127.0.0.1 only; the
    # engine reaches the HA cluster through the pgpool front door (6432).
    cat << ENVEOF > /etc/nms/nms.env
PORT=8000
DATABASE_URL=postgres://rnd_user:${db_pass}@127.0.0.1:6432/rnd_db?sslmode=disable
MIGRATION_DATABASE_URL=postgres://rnd_user:${db_pass}@127.0.0.1:6432/rnd_db?sslmode=disable
PG_PASSWORD=${db_pass}
PG_REPL_PASSWORD=${db_repl_pass}
SECRET_KEY=${secret_key}
ENCRYPTION_KEY=${enc_key}
REDIS_ADDR=127.0.0.1:6379
REDIS_CACHE_ADDR=127.0.0.1:6380
REDIS_PASSWORD=${redis_pass}
NATS_URL=nats://127.0.0.1:4222
NATS_TOKEN=${nats_token}
CLICKHOUSE_ADDR=127.0.0.1:9001
CLICKHOUSE_PASSWORD=${ch_pass}
GRAFANA_CH_PASSWORD=${grafana_ch_pass}
RADIUS_NAS_SECRET=${radius_secret}
DBGATE_ADMIN_PASSWORD=${dbgate_pass}
BACKUP_PASSWORD=${backup_pass}
fm_secret="$(openssl rand -hex 16)"
VICTORIAMETRICS_URL=http://127.0.0.1:8428
FASTNETMON_SECRET=${fm_secret}
APP_ROOT=${ROOT_DIR}
ENVEOF
    chmod 600 /etc/nms/nms.env
fi

# Ensure NMS_REPO and NMS_INSTANCE_NAME are configured
if ! grep -q "^NMS_REPO=" /etc/nms/nms.env 2>/dev/null; then
    echo "NMS_REPO=${ROOT_DIR}" >> /etc/nms/nms.env
fi
if ! grep -q "^NMS_INSTANCE_NAME=" /etc/nms/nms.env 2>/dev/null; then
    echo "NMS_INSTANCE_NAME=MY_NET_NOC" >> /etc/nms/nms.env
fi

# Generate Tier-B (web api) per-instance env files
for i in "${!WEB_INSTANCES[@]}"; do
    port="${WEB_INSTANCES[$i]}"
    cat <<ENV_EOF > "/etc/nms/instances/${port}.env"
NMS_LEADER_PRIORITY=999
NMS_LEADER_KEY=nms:leader:web
ENV_EOF
done

# Generate Tier-A (polling worker) per-instance env files
SYSLOG_BASE=1514; NETFLOW_BASE=2155; SFLOW_BASE=26343
for i in "${!WORKER_INSTANCES[@]}"; do
    port="${WORKER_INSTANCES[$i]}"
    cat <<ENV_EOF > "/etc/nms/workers/${port}.env"
SYSLOG_PORT=$((SYSLOG_BASE + i))
NETFLOW_PORT=$((NETFLOW_BASE + i))
SFLOW_PORT=$((SFLOW_BASE + i))
NMS_LEADER_PRIORITY=$i
NMS_LEADER_KEY=nms:leader:poller
ENV_EOF
done

# Install helper scripts to /usr/local/bin
cp "${ROOT_DIR}/infra/deploy/scripts/engine-ready.sh" /usr/local/bin/nms_engine_ready.sh
chmod +x /usr/local/bin/nms_engine_ready.sh

for script in verify-ha.sh nms_watchdog.sh zero-downtime-deploy.sh ha_daily_check.sh apply_nginx.sh nms-update.sh render-envs.sh apply_secrets.sh apply_redis_auth.sh nms-secrets.sh; do
    if [[ -f "${ROOT_DIR}/infra/deploy/scripts/${script}" ]]; then
        cp "${ROOT_DIR}/infra/deploy/scripts/${script}" "/usr/local/bin/${script}"
        chmod +x "/usr/local/bin/${script}"
    fi
done
ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms-update 2>/dev/null || true
ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms 2>/dev/null || true

# Secret rotation engine: the web wizard (and the operator) apply credential
# changes through the root-owned nms-secrets CLI — the engine user gets a
# narrow NOPASSWD sudoers grant for exactly that one binary.
if [[ -f "${ROOT_DIR}/infra/deploy/scripts/nms-secrets.sh" ]]; then
    cp "${ROOT_DIR}/infra/deploy/scripts/nms-secrets.sh" /usr/local/bin/nms-secrets
    chmod 755 /usr/local/bin/nms-secrets
    printf '%s ALL=(root) NOPASSWD: /usr/local/bin/nms-secrets\n' "${RUN_USER}" > /etc/sudoers.d/nms-secrets
    chmod 440 /etc/sudoers.d/nms-secrets
    visudo -c -f /etc/sudoers.d/nms-secrets >/dev/null || true
fi

# Break-glass recovery: super-admin password/2FA reset from the LOCAL console
# only (SSH refused inside the tool). Last resort when password AND 2FA are
# both lost. Root-owned 0700. Source: backend/cmd build, or the prebuilt
# bundle's bin/ directory.
if [[ -x "${ROOT_DIR}/backend/cmd/nms-admin-reset/nms-admin-reset" || -f "${ROOT_DIR}/bin/nms-admin-reset" ]]; then
    SRC="${ROOT_DIR}/backend/cmd/nms-admin-reset/nms-admin-reset"
    [ -f "${SRC}" ] || SRC="${ROOT_DIR}/bin/nms-admin-reset"
    cp "${SRC}" /usr/local/bin/nms-admin-reset
    chmod 700 /usr/local/bin/nms-admin-reset
elif [[ -f /usr/local/bin/nms-admin-reset ]]; then
    chmod 700 /usr/local/bin/nms-admin-reset
fi

# Render every derived env file / secret-bearing config from the central
# store (idempotent — also heals a partial store by carrying values over).
echo -e "   🔑 Rendering derived env files from /etc/nms/nms.env..."
bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" || true

# Step 8: Configure Nginx & SSL
echo -e "${YELLOW}🔒 [8/9] Configuring Nginx reverse proxy, WAF, and SSL certificates...${NC}"
mkdir -p /etc/nginx/ssl /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d

if [[ -n "${TLS_CERT_DIR}" ]] && [[ -d "${TLS_CERT_DIR}" ]]; then
    # Operator-supplied certificate: accept the common naming variants.
    CERT_SRC="$(find "${TLS_CERT_DIR}" -maxdepth 1 -type f \( -name '*.crt' -o -name '*.pem' -o -name 'fullchain*' \) ! -name '*key*' | head -1)"
    KEY_SRC="$(find "${TLS_CERT_DIR}" -maxdepth 1 -type f \( -name '*.key' -o -name '*privkey*' -o -name '*key*.pem' \) | head -1)"
    if [ -n "${CERT_SRC}" ] && [ -n "${KEY_SRC}" ]; then
        mkdir -p /etc/nginx/ssl
        install -m 644 "${CERT_SRC}" /etc/nginx/ssl/nms_chain.crt
        install -m 600 "${KEY_SRC}" /etc/nginx/ssl/nms.key
        echo -e "   ✅ Operator TLS certificate installed from ${TLS_CERT_DIR}"
    else
        echo -e "   ⚠️  --tls-cert: no cert/key pair found in ${TLS_CERT_DIR} — falling back to self-signed"
    fi
fi
if [[ ! -f /etc/nginx/ssl/nms_chain.crt || ! -f /etc/nginx/ssl/nms.key ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/nms.key \
        -out /etc/nginx/ssl/nms_chain.crt \
        -subj "/C=BD/ST=Dhaka/L=Dhaka/O=MY_NET NOC/CN=localhost" 2>/dev/null
fi
if [[ ! -f /etc/nginx/ssl/dhparam.pem ]]; then
    openssl dhparam -dsaparam -out /etc/nginx/ssl/dhparam.pem 2048 2>/dev/null || true
fi
if [[ ! -f /etc/nginx/.htpasswd ]]; then
    # Generate cryptographically secure 16-char password
    ADMIN_PASS=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)
    HASH=$(openssl passwd -apr1 "$ADMIN_PASS")
    printf "admin:%s\n" "$HASH" > /etc/nginx/.htpasswd
    echo ""
    echo "============================================"
    echo "NGINX BASIC AUTH CREDENTIALS (SAVE NOW):"
    echo "  User: admin"
    echo "  Pass: $ADMIN_PASS"
    echo "============================================"
    echo ""
fi

cp "${ROOT_DIR}/infra/deploy/nginx/waf-rules.conf" /etc/nginx/waf-rules.conf 2>/dev/null || true
# nms_proxy includes this file at the server AND location level (nginx drops
# parent add_header when a location defines its own). Without it nginx -t fails.
cp "${ROOT_DIR}/infra/deploy/nginx/nms_security_headers.conf" /etc/nginx/nms_security_headers.conf 2>/dev/null || true
cp "${ROOT_DIR}/infra/deploy/nginx/performance.conf" /etc/nginx/conf.d/performance.conf 2>/dev/null || true
cp "${ROOT_DIR}/infra/deploy/nginx/engine_upstream.conf" /etc/nginx/conf.d/engine_upstream.conf 2>/dev/null || true

sed "s|{{APP_ROOT}}|${ROOT_DIR}|g" "${ROOT_DIR}/infra/deploy/nginx/nms_proxy.template" > /etc/nginx/sites-available/nms_proxy
ln -sf /etc/nginx/sites-available/nms_proxy /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx || systemctl restart nginx

# Step 9: Launch Docker Infrastructure & Split-Role Engine Cluster (8 instances)
echo -e "${YELLOW}🚀 [9/9] Booting Docker clusters and launching 8-instance split-role engine...${NC}"
cd "${ROOT_DIR}/infra/deploy/db_cluster"
docker compose up -d 2>/dev/null || true

cd "${ROOT_DIR}/infra/deploy/nms_stack"
docker compose up -d

# ── ClickHouse analytics schema bootstrap (PLAN_013 follow-up) ───────────
# The flow/syslog/sflow/radius-acct tables are NOT auto-created by the CH
# image — without them the telemetry pipeline has nowhere to write. Wait
# for ClickHouse to accept connections, then apply the idempotent schema.
# Password comes from the central store (never printed).
echo -e "   🧮 Bootstrapping ClickHouse analytics schema..."
CH_PASS="$(grep -E '^CLICKHOUSE_PASSWORD=' "${NMS_ENV:-/etc/nms/nms.env}" | head -1 | cut -d= -f2-)"
CH_WAIT=0
until curl -s -m 3 "http://127.0.0.1:8123/ping" >/dev/null 2>&1; do
    CH_WAIT=$((CH_WAIT + 2))
    if [ "${CH_WAIT}" -ge 60 ]; then
        echo -e "   ⚠️  ClickHouse did not answer in 60s — skipping schema bootstrap (re-run the .sql later)"
        break
    fi
    sleep 2
done
if [ -f "${ROOT_DIR}/infra/deploy/nms_stack/clickhouse-analytics-schema.sql" ]; then
    tr ';' '\n' < "${ROOT_DIR}/infra/deploy/nms_stack/clickhouse-analytics-schema.sql" \
      | grep -vE '^\s*$' \
      | while IFS= read -r stmt; do
            curl -s -m 15 "http://127.0.0.1:8123/" --user "default:${CH_PASS}" --data-binary "${stmt}" >/dev/null
        done
    echo -e "   ✅ Analytics tables verified/created (4/4)"
fi

# Deploy systemd unit templates
sed -e "s|{{APP_ROOT}}|${ROOT_DIR}|g" \
    -e "s|{{SYS_USER}}|${RUN_USER}|g" \
    -e "s|{{SYS_GROUP}}|${RUN_GROUP}|g" \
    "${ROOT_DIR}/infra/deploy/systemd/nms_engine@.service.template" > /etc/systemd/system/nms_engine@.service

sed -e "s|{{APP_ROOT}}|${ROOT_DIR}|g" \
    -e "s|{{SYS_USER}}|${RUN_USER}|g" \
    -e "s|{{SYS_GROUP}}|${RUN_GROUP}|g" \
    "${ROOT_DIR}/infra/deploy/systemd/nms_worker@.service.template" > /etc/systemd/system/nms_worker@.service

mkdir -p /etc/systemd/system/nms_engine@.service.d
sed "s|{{APP_ROOT}}|${ROOT_DIR}|g" \
    "${ROOT_DIR}/infra/deploy/systemd/hardening.conf" > /etc/systemd/system/nms_engine@.service.d/hardening.conf

# Workers have the same attack surface as the engine — give them the
# identical hardening drop-in (previously only the engine was hardened).
mkdir -p /etc/systemd/system/nms_worker@.service.d
sed "s|{{APP_ROOT}}|${ROOT_DIR}|g" \
    "${ROOT_DIR}/infra/deploy/systemd/hardening.conf" > /etc/systemd/system/nms_worker@.service.d/hardening.conf

cp "${ROOT_DIR}/infra/deploy/systemd/nms_watchdog.service" /etc/systemd/system/ 2>/dev/null || true
cp "${ROOT_DIR}/infra/deploy/systemd/nms_watchdog.timer" /etc/systemd/system/ 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now nms_watchdog.timer 2>/dev/null || true

echo -e "${YELLOW}  Starting Tier-B Web API cluster (ports: ${WEB_INSTANCES[*]})...${NC}"
for port in "${WEB_INSTANCES[@]}"; do
    systemctl enable "nms_engine@${port}" --now || true
done

echo -e "${YELLOW}  Starting Tier-A Polling Worker cluster (ports: ${WORKER_INSTANCES[*]})...${NC}"
for port in "${WORKER_INSTANCES[@]}"; do
    systemctl enable "nms_worker@${port}" --now || true
done

echo ""
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN} 🎉 MY_NET Enterprise NOC Provisioning Complete!${NC}"
echo -e "${GREEN}======================================================================${NC}"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "${SERVER_IP}" ] || SERVER_IP="localhost"
CERT_FPR="$(openssl x509 -in /etc/nginx/ssl/nms_chain.crt -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true)"
echo -e " 🖥️  Web Portal      : ${CYAN}https://${SERVER_IP}${NC}"
echo -e " 🐳  Portainer Docker: ${CYAN}https://${SERVER_IP}:8082${NC}"
echo -e " 📦  Gitea Git Server: ${CYAN}https://${SERVER_IP}:8083${NC}"
if [ -n "${CERT_FPR}" ]; then
    echo -e " 🔒 TLS fingerprint  : ${CYAN}${CERT_FPR}${NC}"
    echo -e "    ${YELLOW}Self-signed cert — before first login, match this SHA256${NC}"
    echo -e "    ${YELLOW}in your browser's certificate details to rule out MITM.${NC}"
    echo -e "    ${YELLOW}Bring your own cert anytime: sudo bash setup.sh --tls-cert <dir-with-cert-and-key>${NC}"
fi
echo ""
echo -e " 👨‍💻 Creator & Lead Architect: ${CYAN}Md. Mahamudul Hassan Khan${NC}"
echo -e " 🔗 LinkedIn Profile        : ${CYAN}https://www.linkedin.com/in/md-mahamudul-hassan-khan/${NC}"

if [ -f /etc/nms/.setup-pin-hash ] && [ ! -f /etc/nms/.initialized ]; then
    echo ""
    echo -e "${YELLOW}+------------------------------------------------------+${NC}"
    echo -e "${YELLOW}|  FIRST-RUN SETUP REQUIRED                             |${NC}"
    echo -e "${YELLOW}|  Open:  https://${SERVER_IP}/setup${NC}"
    echo -e "${YELLOW}|  Enter this ONE-TIME PIN (valid 60 minutes):          |${NC}"
    echo -e "${GREEN}|                                                       |${NC}"
    echo -e "${GREEN}|        SETUP PIN: ${SETUP_PIN:-<regenerate>}              |${NC}"
    echo -e "${GREEN}|                                                       |${NC}"
    echo -e "${YELLOW}|  Lost it? Regenerate: sudo bash setup.sh --regen-pin  |${NC}"
    echo -e "${YELLOW}+------------------------------------------------------+${NC}"
fi
echo -e "${GREEN}======================================================================${NC}"
