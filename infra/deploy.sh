#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# NMS Enterprise — One-Command Deploy Script
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh [OPTIONS]
#
# Options:
#   --tag      Docker image tag  (default: git short SHA)
#   --env      Environment file  (default: .env)
#   --compose  docker-compose file to use (default: deploy/nms_stack/docker-compose.yml)
#   --skip-build   Skip Docker image build (use existing tag)
#   --skip-tests   Skip Go test suite before build
#   --monitoring   Also start the Prometheus/Grafana monitoring stack
#
# Examples:
#   ./deploy.sh
#   ./deploy.sh --tag v1.2.3 --monitoring
#   ./deploy.sh --skip-build --tag latest
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Default values ────────────────────────────────────────────────────────────
IMAGE_NAME="nms-engine"
TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
ENV_FILE=".env"
COMPOSE_FILE="deploy/nms_stack/docker-compose.yml"
SKIP_BUILD=false
SKIP_TESTS=false

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)       TAG="$2"; shift 2 ;;
    --env)       ENV_FILE="$2"; shift 2 ;;
    --compose)   COMPOSE_FILE="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --skip-tests) SKIP_TESTS=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

FULL_IMAGE="${IMAGE_NAME}:${TAG}"

# ── Helper ────────────────────────────────────────────────────────────────────
log() { echo -e "\033[1;32m[DEPLOY]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERROR ]\033[0m $*" >&2; exit 1; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
log "Checking prerequisites..."
command -v docker   >/dev/null || err "docker not found"
command -v docker compose &>/dev/null || err "docker compose not found"

[[ -f "$ENV_FILE" ]] || err "Environment file '$ENV_FILE' not found. Copy .env.example and fill in values."

# ── Run Tests ─────────────────────────────────────────────────────────────────
if [[ "$SKIP_TESTS" == false ]]; then
  log "Running Go test suite..."
  (cd backend && go test ./... -timeout 60s) || err "Tests failed. Aborting deploy."
  log "✅ All tests passed."
fi

# ── Build React Frontend ──────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]]; then
  log "Building React Frontend..."
  (cd frontend && npm install && npm run build) || err "Frontend build failed"

  log "Building Go Backend..."
  cd backend
  go build -o ../nms_engine ./cmd/nms_engine
  go build -o ../telegram-relay ./cmd/telegram-relay
  go build -o ../rcli ./cmd/rcli
  cd ..
  log "✅ Application built successfully"
else
  log "Skipping build (--skip-build)"
fi

# ── Deploy Infrastructure via Compose ─────────────────────────────────────────
log "Deploying infrastructure via: $COMPOSE_FILE ..."
docker compose \
  --env-file "$ENV_FILE" \
  -f "$COMPOSE_FILE" \
  up -d --remove-orphans
log "✅ Core infrastructure is up."

# ── Setup Systemd Services (First time install) ─────────────────────────────
if [ ! -f "/etc/systemd/system/nms_engine@.service" ]; then
  log "Setting up systemd services for the first time..."
  sudo mkdir -p /etc/nms/instances
  sudo cp "$ENV_FILE" /etc/nms/nms.env
  
  # Create nms_engine_ready.sh
  cat << 'EOF' | sudo tee /usr/local/bin/nms_engine_ready.sh >/dev/null
#!/bin/bash
# Pre-start script for NMS Engine
echo "NMS Engine is ready to start."
EOF
  sudo chmod +x /usr/local/bin/nms_engine_ready.sh

  sudo systemctl daemon-reload
  sudo systemctl enable nms_engine@{8000..8004}.service
fi

# ── Install & Restart Systemd ─────────────────────────────────────────────────
log "Installing binaries to /usr/local/bin and restarting systemd..."
sudo systemctl stop nms_engine@{8000..8004}.service || true

SYS_USER=$(whoami)
SYS_GROUP=$(id -gn)
APP_ROOT=$(pwd)
sed -e "s|{{SYS_USER}}|$SYS_USER|g" -e "s|{{SYS_GROUP}}|$SYS_GROUP|g" -e "s|{{APP_ROOT}}|$APP_ROOT|g" infra/deploy/systemd/nms_engine@.service.template | sudo tee /etc/systemd/system/nms_engine@.service >/dev/null
sed -e "s|{{SYS_USER}}|$SYS_USER|g" -e "s|{{SYS_GROUP}}|$SYS_GROUP|g" -e "s|{{APP_ROOT}}|$APP_ROOT|g" infra/deploy/systemd/nms-telegram-relay.service.template | sudo tee /etc/systemd/system/nms-telegram-relay.service >/dev/null
sed -e "s|{{SYS_USER}}|$SYS_USER|g" -e "s|{{SYS_GROUP}}|$SYS_GROUP|g" -e "s|{{APP_ROOT}}|$APP_ROOT|g" infra/deploy/backup/nms_backup.service.template | sudo tee /etc/systemd/system/nms_backup.service >/dev/null

sudo rm -f /usr/local/bin/nms_engine /usr/local/bin/telegram-relay /usr/local/bin/rcli
sudo cp nms_engine /usr/local/bin/nms_engine
sudo cp telegram-relay /usr/local/bin/telegram-relay
sudo cp rcli /usr/local/bin/rcli
sudo mkdir -p /usr/local/bin/static
sudo cp -r frontend/dist /usr/local/bin/static/dist
sudo systemctl daemon-reload
# Restarting the 5 instances running on ports 8000-8004
sudo systemctl restart nms_engine@{8000..8004}.service
sudo systemctl restart nms-telegram-relay.service || true
log "✅ Systemd workers restarted."


# ── Health check ──────────────────────────────────────────────────────────────
log "Waiting for NMS Engine to be healthy..."
RETRIES=12
for i in $(seq 1 $RETRIES); do
  if curl -sf http://localhost:8000/health >/dev/null 2>&1; then
    log "✅ NMS Engine is healthy!"
    break
  fi
  if [[ $i -eq $RETRIES ]]; then
    err "NMS Engine did not become healthy after ${RETRIES} attempts."
  fi
  sleep 5
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║          ✅  DEPLOY COMPLETE                 ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Image   : $FULL_IMAGE"
echo "║  Compose : $COMPOSE_FILE"
echo "╚══════════════════════════════════════════════╝"
