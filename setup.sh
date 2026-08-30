#!/usr/bin/env bash
# ==============================================================================
# MY_NET Enterprise NOC — 1-Click Automated Turnkey Installer (Split-Role HA)
# Author: Md. Mahamudul Hassan Khan (https://www.linkedin.com/in/md-mahamudul-hassan-khan/)
# License: GNU AGPLv3 with Mandatory Author Attribution
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "======================================================================"
echo " 🌐 MY_NET Enterprise NOC — 1-Click Turnkey Setup (8-Instance Split-Role)"
echo " Lead Architect: Md. Mahamudul Hassan Khan"
echo " LinkedIn      : https://www.linkedin.com/in/md-mahamudul-hassan-khan/"
echo "======================================================================"
echo -e "${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This installer must be run with root privileges. Please run: sudo bash setup.sh${NC}"
   exit 1
fi

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_INSTANCES=(8000 8001 8002 8003 8004)
WORKER_INSTANCES=(9000 9001 9002)

# Step 1: Install OS dependencies
echo -e "${YELLOW}📦 [1/8] Installing host packages (nginx, curl, jq, openssl, rsync)...${NC}"
apt-get update -qq && apt-get install -y -qq nginx curl jq openssl rsync ca-certificates gnupg lsb-release

# Step 2: Ensure Docker Engine
echo -e "${YELLOW}🐳 [2/8] Checking Docker Engine...${NC}"
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

# Step 3: Install pre-compiled Engine Binary & Helper Scripts
echo -e "${YELLOW}⚙️ [3/8] Deploying high-performance Go engine binary...${NC}"
cp "${INSTALL_DIR}/bin/nms_engine" /usr/local/bin/nms_engine
chmod +x /usr/local/bin/nms_engine

if [[ -f "${INSTALL_DIR}/infra/deploy/scripts/engine-ready.sh" ]]; then
    cp "${INSTALL_DIR}/infra/deploy/scripts/engine-ready.sh" /usr/local/bin/nms_engine_ready.sh
    chmod +x /usr/local/bin/nms_engine_ready.sh
fi

for script in verify-ha.sh nms_watchdog.sh zero-downtime-deploy.sh ha_daily_check.sh; do
    if [[ -f "${INSTALL_DIR}/infra/deploy/scripts/${script}" ]]; then
        cp "${INSTALL_DIR}/infra/deploy/scripts/${script}" "/usr/local/bin/${script}"
        chmod +x "/usr/local/bin/${script}"
    fi
done

# Step 4: Configure Environment & Instance Configurations
echo -e "${YELLOW}🔧 [4/8] Generating environment configurations (/etc/nms)...${NC}"
mkdir -p /etc/nms/instances /etc/nms/workers
if [[ ! -f /etc/nms/nms.env ]]; then
    cat << 'ENVEOF' > /etc/nms/nms.env
PORT=8000
DATABASE_URL=postgres://rnd_user:rnd_password@127.0.0.1:5432/rnd_db?sslmode=disable
REDIS_ADDR=127.0.0.1:6379
REDIS_CACHE_ADDR=127.0.0.1:6380
ENCRYPTION_KEY=c4rb0n4d0_nms_aes_master_secret_2026_key
NATS_URL=nats://127.0.0.1:4222
CLICKHOUSE_ADDR=127.0.0.1:9001
VICTORIAMETRICS_URL=http://127.0.0.1:8428
APP_ROOT=/opt/my_net_noc
ENVEOF
fi

# Generate Tier-B (web) env files
for i in "${!WEB_INSTANCES[@]}"; do
    port="${WEB_INSTANCES[$i]}"
    cat << ENV_EOF > "/etc/nms/instances/${port}.env"
NMS_LEADER_PRIORITY=999
NMS_LEADER_KEY=nms:leader:web
ENV_EOF
done

# Generate Tier-A (polling worker) env files
SYSLOG_BASE=1514; NETFLOW_BASE=2155; SFLOW_BASE=26343
for i in "${!WORKER_INSTANCES[@]}"; do
    port="${WORKER_INSTANCES[$i]}"
    cat << ENV_EOF > "/etc/nms/workers/${port}.env"
SYSLOG_PORT=$((SYSLOG_BASE + i))
NETFLOW_PORT=$((NETFLOW_BASE + i))
SFLOW_PORT=$((SFLOW_BASE + i))
NMS_LEADER_PRIORITY=$i
NMS_LEADER_KEY=nms:leader:poller
ENV_EOF
done

# Step 5: Generate SSL Certificates if missing
echo -e "${YELLOW}🔒 [5/8] Generating SSL certificates for Nginx HTTPS proxy...${NC}"
mkdir -p /etc/nginx/ssl
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
    printf "admin:\$apr1\$nms\$Y8qYv0q7Uo6.n1gX1m8s80\n" > /etc/nginx/.htpasswd
fi

# Step 6: Configure Nginx & Deploy Frontend
echo -e "${YELLOW}🌐 [6/8] Deploying React frontend and Nginx Reverse Proxy WAF...${NC}"
mkdir -p /var/www/nms_frontend /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d
cp -r "${INSTALL_DIR}/frontend/dist/"* /var/www/nms_frontend/ 2>/dev/null || true

cp "${INSTALL_DIR}/infra/deploy/nginx/waf-rules.conf" /etc/nginx/waf-rules.conf 2>/dev/null || true
cp "${INSTALL_DIR}/infra/deploy/nginx/performance.conf" /etc/nginx/conf.d/performance.conf 2>/dev/null || true
cp "${INSTALL_DIR}/infra/deploy/nginx/engine_upstream.conf" /etc/nginx/conf.d/engine_upstream.conf 2>/dev/null || true

sed "s|{{APP_ROOT}}|${INSTALL_DIR}|g" "${INSTALL_DIR}/infra/deploy/nginx/nms_proxy.template" > /etc/nginx/sites-available/nms_proxy
ln -sf /etc/nginx/sites-available/nms_proxy /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx || systemctl restart nginx

# Step 7: Boot Docker Infrastructure & Split-Role Engine Cluster
echo -e "${YELLOW}🚀 [7/8] Booting Docker stack and 8-instance split-role engine...${NC}"
cd "${INSTALL_DIR}/infra/deploy/nms_stack"
docker compose up -d

# Step 8: Install Systemd Service Templates for Web & Polling Clusters
echo -e "${YELLOW}⚙️ [8/8] Launching systemd services (5 Web API + 3 Polling Workers)...${NC}"
cat << 'SYSEOF' > /etc/systemd/system/nms_engine@.service
[Unit]
Description=NMS Web API Engine (instance %i)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStartPre=/usr/local/bin/nms_engine_ready.sh
ExecStart=/usr/local/bin/nms_engine --api
Restart=always
RestartSec=3
EnvironmentFile=/etc/nms/nms.env
EnvironmentFile=-/etc/nms/instances/%i.env
Environment="APP_ROOT=/opt/my_net_noc"
Environment="PORT=%i"
Environment="GOGC=200"
Environment="GOMEMLIMIT=256MiB"
Environment="GOMAXPROCS=2"
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SYSEOF

cat << 'SYSEOF' > /etc/systemd/system/nms_worker@.service
[Unit]
Description=NMS Polling Worker Engine (instance %i)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStartPre=/usr/local/bin/nms_engine_ready.sh
ExecStart=/usr/local/bin/nms_engine --poller --bgp --syslog --netflow
Restart=always
RestartSec=3
EnvironmentFile=/etc/nms/nms.env
EnvironmentFile=-/etc/nms/workers/%i.env
Environment="APP_ROOT=/opt/my_net_noc"
Environment="PORT=%i"
Environment="GOGC=300"
Environment="GOMEMLIMIT=192MiB"
Environment="GOMAXPROCS=2"
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SYSEOF

systemctl daemon-reload

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
echo -e "${GREEN} 🎉 MY_NET Enterprise NOC Installation Succeeded!${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo -e " 🖥️  Web Portal      : ${CYAN}https://localhost${NC} (or your server public IP)"
echo -e " 📊  Grafana Metrics : ${CYAN}https://localhost:8081${NC}"
echo -e " 🐳  Portainer Docker: ${CYAN}https://localhost:8082${NC}"
echo -e " 📦  Gitea Git Server: ${CYAN}https://localhost:8083${NC}"
echo ""
echo -e " 👨‍💻 Creator & Lead Architect: ${CYAN}Md. Mahamudul Hassan Khan${NC}"
echo -e " 🔗 LinkedIn Profile        : ${CYAN}https://www.linkedin.com/in/md-mahamudul-hassan-khan/${NC}"
echo -e "${GREEN}======================================================================${NC}"
