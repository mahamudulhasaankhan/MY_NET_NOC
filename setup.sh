#!/usr/bin/env bash
# ==============================================================================
# MY_NET NOC — 1-Click Master Developer & Production Server Provisioner
# Author: Md. Mahamudul Hassan Khan (https://www.linkedin.com/in/md-mahamudul-hassan-khan/)
# Copyright (c) 2026 Md. Mahamudul Hassan Khan. All rights reserved.
# ==============================================================================
set -euo pipefail

# ── Preflight: root + base state directory (fresh-install safe) ───────────────
# Run BEFORE arg parsing: --regen-pin previously bypassed the EUID check below.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "FATAL: this installer must run as root (sudo bash setup.sh)" >&2
    exit 1
fi
NMS_STATE_DIR="/etc/nms"
mkdir -p "${NMS_STATE_DIR}"/{instances,workers}
chmod 755 "${NMS_STATE_DIR}"
umask 077
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "${RUN_USER}" 2>/dev/null || echo "${RUN_USER}")"
trap 'rm -f "${NMS_STATE_DIR}/.setup-pin-hash.tmp."*' EXIT
trap 'echo "❌ setup.sh failed at line $LINENO" >&2' ERR

TLS_CERT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --regen-pin)
            mkdir -p "${NMS_STATE_DIR}"
            P1="$(openssl rand -hex 2 | tr 'a-f' 'A-F')"
            P2="$(openssl rand -hex 2 | tr 'a-f' 'A-F')"
            SETUP_PIN="${P1}-${P2}"
            PIN_TMP="/etc/nms/.setup-pin-hash.tmp.$$"
            printf "%s" "$SETUP_PIN" | sha256sum | awk '{print $1}' > "$PIN_TMP"
            chmod 600 "$PIN_TMP"
            mv -f "$PIN_TMP" /etc/nms/.setup-pin-hash
    chown "${RUN_USER}:${RUN_GROUP}" /etc/nms/.setup-pin-hash 2>/dev/null || true
    chmod 600 /etc/nms/.setup-pin-hash 2>/dev/null || true

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
    mkdir -p "${NMS_STATE_DIR}"
    P1="$(openssl rand -hex 2 | tr 'a-f' 'A-F')"
    P2="$(openssl rand -hex 2 | tr 'a-f' 'A-F')"
    SETUP_PIN="${P1}-${P2}"
    PIN_TMP="/etc/nms/.setup-pin-hash.tmp.$$"
    printf "%s" "$SETUP_PIN" | sha256sum | awk '{print $1}' > "$PIN_TMP"
    chmod 600 "$PIN_TMP"
    mv -f "$PIN_TMP" /etc/nms/.setup-pin-hash
    chown "${RUN_USER}:${RUN_GROUP}" /etc/nms/.setup-pin-hash 2>/dev/null || true
    chmod 600 /etc/nms/.setup-pin-hash 2>/dev/null || true

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

# ── BINARY vs SOURCE mode ─────────────────────────────────────────────────
# Public-repo installs ship pre-built binaries: bin/nms_engine + frontend/dist.
# In that mode the Go/Node toolchains are NEVER installed or needed.
BINARY_MODE=false
if [[ -f "${ROOT_DIR}/bin/nms_engine" && -d "${ROOT_DIR}/frontend/dist" ]]; then
    BINARY_MODE=true
    echo -e "${CYAN}📦 Pre-built distribution detected → BINARY install mode (no compilers)${NC}"
    for _f in bin/nms_engine frontend/dist/index.html; do
        [[ -e "${ROOT_DIR}/${_f}" ]] || { echo -e "${RED}❌ FATAL: missing ${_f} in bundle${NC}"; exit 1; }
    done
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
    # Single-source the version from the repo-root VERSION file when the caller
    # did not export one — keeps SOURCE-mode builds stamped with the real release
    # version instead of the 1.0.0 brand fallback (which caused a version mismatch).
    BUILD_VERSION="${VERSION:-$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION" 2>/dev/null || true)}"
    BUILD_VERSION="${BUILD_VERSION:-1.0.0}"
    CGO_ENABLED=0 go build -ldflags="-s -w -X 'nms_engine/internal/brand.Version=${BUILD_VERSION}'" -o nms_engine ./cmd/nms_engine
    cp nms_engine /usr/local/bin/nms_engine
fi
chmod 755 /usr/local/bin/nms_engine

# Companion binaries (relay/rcli) if shipped; break-glass tool ships 0700
for b in telegram-relay rcli nms-admin-reset; do
    [[ -f "${ROOT_DIR}/bin/$b" ]] && { cp "${ROOT_DIR}/bin/$b" /usr/local/bin/; chmod 755 "/usr/local/bin/$b"; }
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
mkdir -p /usr/local/bin/static/dist "${ROOT_DIR}/uploads" "${ROOT_DIR}/data"
chown -R "${RUN_USER}:${RUN_GROUP}" "${ROOT_DIR}/data" "${ROOT_DIR}/uploads" 2>/dev/null || true
# Fix umask 077 side-effect: nginx (www-data) must traverse + read static dist
chmod 755 /usr/local/bin/static /usr/local/bin/static/dist
rsync -a --delete "${ROOT_DIR}/frontend/dist/" /usr/local/bin/static/dist/
echo "   ✅ Frontend deployed to /usr/local/bin/static/dist (+ uploads dir ready)"

# Step 7: Deploy Environment Configurations & Helper Scripts
echo -e "${YELLOW}🔧 [7/9] Configuring environment, secrets, and helper scripts...${NC}"
mkdir -p /etc/nms/instances /etc/nms/workers

# PostgreSQL app credentials (prompted on first run; env var override supported)
if [[ -z "${PG_USERNAME:-}" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "PostgreSQL app username [rnd_user]: " PG_USERNAME
    fi
    PG_USERNAME="${PG_USERNAME:-rnd_user}"
fi
pg_user="${PG_USERNAME}"

# Heal a partially-written/broken nms.env from a previous failed run
# (e.g. the fm_secret-unbound crash left an incomplete store).
if [[ -f /etc/nms/nms.env ]] && ! grep -q '^FASTNETMON_SECRET=.' /etc/nms/nms.env; then
    echo -e "${YELLOW}⚠️  detected broken /etc/nms/nms.env (missing FASTNETMON_SECRET) — backing up & regenerating${NC}"
    cp /etc/nms/nms.env "/etc/nms/nms.env.bak.broken.$(date +%s)"
    rm -f /etc/nms/nms.env
fi

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
    fm_secret="$(openssl rand -hex 16)"
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
PG_USERNAME=${pg_user}
PG_DATABASE=rnd_db
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
# Install readiness check (ExecStartPre of nms_engine@.service). Guard against a
# missing source file: if the bundle omitted it, synthesize a no-op so systemd
# does not fail with "No such file or directory" and crash-loop the service.
if [[ -f "${ROOT_DIR}/infra/deploy/scripts/engine-ready.sh" ]]; then
    install -m 755 "${ROOT_DIR}/infra/deploy/scripts/engine-ready.sh" /usr/local/bin/nms_engine_ready.sh
else
    printf '#!/bin/sh\n# fallback readiness check (source missing)\nexit 0\n' > /usr/local/bin/nms_engine_ready.sh
    chmod 755 /usr/local/bin/nms_engine_ready.sh
fi
[[ -x /usr/local/bin/nms_engine_ready.sh ]] || { echo -e "${RED}❌ FATAL: nms_engine_ready.sh not installed${NC}"; exit 1; }

for script in verify-ha.sh nms_watchdog.sh zero-downtime-deploy.sh ha_daily_check.sh apply_nginx.sh nms-update.sh verify-install.sh render-envs.sh apply_secrets.sh apply_redis_auth.sh nms-secrets.sh nms-full-backup.sh nms-full-restore.sh nms-uninstall.sh; do
    if [[ -f "${ROOT_DIR}/infra/deploy/scripts/${script}" ]]; then
        cp "${ROOT_DIR}/infra/deploy/scripts/${script}" "/usr/local/bin/${script}"
        chmod 755 "/usr/local/bin/${script}"
    fi
done
ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms-update 2>/dev/null || true
ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms 2>/dev/null || true
ln -sf /usr/local/bin/nms-update.sh /usr/local/bin/nms-upgrade 2>/dev/null || true
ln -sf /usr/local/bin/nms-uninstall.sh /usr/local/bin/nms-uninstall 2>/dev/null || true

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

# Software update: the Settings "Check for Updates → Upgrade" action lets the
# engine user trigger the root self-updater without a password prompt. Narrow
# NOPASSWD grant for exactly the nms-update.sh binary (same model as above).
if [[ -f /usr/local/bin/nms-update.sh ]]; then
    chmod 755 /usr/local/bin/nms-update.sh
    printf '%s ALL=(root) NOPASSWD: /usr/local/bin/nms-update.sh\n' "${RUN_USER}" > /etc/sudoers.d/nms-update
    chmod 440 /etc/sudoers.d/nms-update
    visudo -c -f /etc/sudoers.d/nms-update >/dev/null || true
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

# Step 7.5: Apply kernel security hardening (syncookies, rp_filter, nonlocal bind)
# nms_proxy.template binds nginx to 172.17.0.1 (docker0) which may not exist
# yet at boot — ip_nonlocal_bind=1 lets nginx bind anyway.
echo -e "${YELLOW}🛡️  [7.5/9] Applying kernel security hardening (sysctl)...${NC}"
if [[ -f "${ROOT_DIR}/infra/deploy/sysctl/99-nms-security.conf" ]]; then
    cp "${ROOT_DIR}/infra/deploy/sysctl/99-nms-security.conf" /etc/sysctl.d/99-nms-security.conf
    sysctl --system >/dev/null 2>&1 || sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1 || true
    echo -e "   ✅ Kernel hardening applied (ip_nonlocal_bind=1)"
else
    # Fallback: at least enable nonlocal bind for nginx boot safety
    echo "net.ipv4.ip_nonlocal_bind = 1" > /etc/sysctl.d/99-nms-nonlocal-bind.conf
    sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1 || true
fi

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
# waf-custom-maps.conf and waf-enabled.conf are generated at runtime by the
# WAF Control Center; create empty placeholders so nginx -t passes on first boot.
touch /etc/nginx/waf-custom-maps.conf /etc/nginx/waf-enabled.conf
chmod 644 /etc/nginx/waf-custom-maps.conf /etc/nginx/waf-enabled.conf
cp "${ROOT_DIR}/infra/deploy/nginx/engine_upstream.conf" /etc/nginx/conf.d/engine_upstream.conf 2>/dev/null || true

sed "s|{{APP_ROOT}}|${ROOT_DIR}|g" "${ROOT_DIR}/infra/deploy/nginx/nms_proxy.template" > /etc/nginx/sites-available/nms_proxy
ln -sf /etc/nginx/sites-available/nms_proxy /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && (systemctl is-active --quiet nginx && systemctl reload nginx || systemctl restart nginx) 2>/dev/null || systemctl restart nginx

# Make nginx wait for docker0 on boot so it never crashes when docker0 is late.
# ip_nonlocal_bind=1 (set above) already lets nginx bind to 172.17.0.1 even
# before docker0 exists; this drop-in adds an explicit ordering for safety.
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/10-nms-docker-order.conf <<'EOF'
[Unit]
After=docker.service docker.socket network-online.target
Wants=docker.service network-online.target
EOF
systemctl daemon-reload 2>/dev/null || true

# Step 9: Launch Docker Infrastructure & Split-Role Engine Cluster (8 instances)
echo -e "${YELLOW}🚀 [9/9] Booting Docker clusters and launching 8-instance split-role engine...${NC}"
# db_cluster ships in BOTH source checkouts and the distribution bundle
# (publish_public.sh stages infra/deploy/db_cluster/ — only its rendered
# secrets/.env are kept out and regenerated by render-envs.sh above). A
# missing directory means an incomplete download: fail with an actionable
# message instead of dying inside `cd` under `set -e`.
if [[ ! -d "${ROOT_DIR}/infra/deploy/db_cluster" ]]; then
    echo -e "${RED}❌ FATAL: infra/deploy/db_cluster/ is missing from ${ROOT_DIR}."
    echo "       The bundle is incomplete — re-download the release and verify"
    echo "       its sha256sums.txt before re-running setup.sh.${NC}"
    exit 1
fi
cd "${ROOT_DIR}/infra/deploy/db_cluster"
# Create BOTH cross-stack networks BEFORE starting either compose stack.
docker network inspect db_cluster_default >/dev/null 2>&1 || docker network create db_cluster_default >/dev/null
docker network inspect nms_stack_default  >/dev/null 2>&1 || docker network create nms_stack_default  >/dev/null

cd "${ROOT_DIR}/infra/deploy/db_cluster"
if ! docker compose up -d; then
    echo "WARNING: db_cluster compose up reported errors (continuing)"
fi

# nms_stack attaches to db_cluster_default as an EXTERNAL network. Create it
# if db_cluster's `up` above was skipped or failing, so the main stack can
# still start and surface its own (louder) errors.
docker network inspect db_cluster_default >/dev/null 2>&1 || \
    docker network create db_cluster_default >/dev/null

# Run DB schema migrations BEFORE starting nms_stack (which contains
# FreeRADIUS). FreeRADIUS queries the `nas` table on boot; if migrations
# have not run yet the table does not exist and RADIUS auth fails. Running
# --migrate here (idempotent) guarantees the schema is ready first.
echo -e "   🗄️  Applying database schema migrations..."
for i in $(seq 1 30); do
    docker exec pg-pgpool pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break
    sleep 2
done
if [[ -x /usr/local/bin/nms_engine && -r /etc/nms/nms.env ]]; then
    set -a; . /etc/nms/nms.env; set +a
    /usr/local/bin/nms_engine --migrate 2>&1 | tail -3 || echo "   ⚠️  migration reported errors (engine re-checks in-process at boot)"
fi

# Create sentinel runtime dirs (gitignored, not shipped in bundle) and seed
# them with the clean template so apply_redis_auth.sh and docker compose
# (./sentinel/sN:/sentinel) find sentinel.conf on a fresh install.
mkdir -p "${ROOT_DIR}/infra/deploy/nms_stack/sentinel"/{s1,s2,s3}
for d in s1 s2 s3; do
    target="${ROOT_DIR}/infra/deploy/nms_stack/sentinel/${d}/sentinel.conf"
    template="${ROOT_DIR}/infra/deploy/nms_stack/sentinel/sentinel.conf.template"
    if [[ ! -f "$target" && -f "$template" ]]; then
        case "$d" in
            s1) port=26379 ;;
            s2) port=26380 ;;
            s3) port=26381 ;;
            *)  port=26379 ;;
        esac
        sed "s/^port .*/port ${port}/" "$template" > "$target"
        chown 999:999 "$target" 2>/dev/null || true
        chmod 640 "$target"
    fi
done

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
