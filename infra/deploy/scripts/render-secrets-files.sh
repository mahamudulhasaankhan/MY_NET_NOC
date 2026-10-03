#!/usr/bin/env bash
# ==============================================================================
# MY_NET NOC — R2 file-based secret rendering (part of render-envs.sh flow)
# Renders per-service secret CONFIG FILES (0600) so containers never carry
# credentials in env vars or argv — `docker inspect` shows nothing usable.
# ==============================================================================
set -euo pipefail

NMS_ENV="${NMS_ENV:-/etc/nms/nms.env}"
# Resolve repo root exactly like render-envs.sh (store NMS_REPO wins).
ROOT_DIR="${NMS_ROOT_DIR:-${NMS_REPO:-$(grep -E '^NMS_REPO=' "${NMS_ENV}" 2>/dev/null | head -1 | cut -d= -f2-)}}"
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# Load the central store — the secret values come from here.
# shellcheck disable=SC1090
set -a; . "${NMS_ENV}"; set +a
RENDERED="${RENDERED_DIR:-${ROOT_DIR}/infra/deploy/nms_stack/rendered}"
FREERADIUS_TPL="${ROOT_DIR}/infra/deploy/nms_stack/freeradius"
mkdir -p "${RENDERED}"
# 711: non-root container users (redis uid 999, nats uid 65534) must be able
# to TRAVERSE the directory to reach their 0400 secret files.
chmod 711 "${RENDERED}"
umask 077

: "${PG_PASSWORD:?PG_PASSWORD missing}"
: "${RADIUS_NAS_SECRET:?RADIUS_NAS_SECRET missing}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD missing}"
: "${NATS_TOKEN:?NATS_TOKEN missing}"

# ── freeradius: render sql + clients from templates ─────────────────────────
sed "s/__DB_PASSWORD__/${PG_PASSWORD}/g" \
    "${FREERADIUS_TPL}/sql.conf" > "${RENDERED}/freeradius-sql.conf"
sed "s/__RADIUS_SECRET__/${RADIUS_NAS_SECRET}/g" \
    "${FREERADIUS_TPL}/clients.conf.template" > "${RENDERED}/freeradius-clients.conf"

# ── redis: one config per instance ──────────────────────────────────────────
# redis image entrypoint drops to uid 999 — files must be readable by it.
cat > "${RENDERED}/redis-queue.conf" << EOF
requirepass ${REDIS_PASSWORD}
maxmemory 256mb
maxmemory-policy noeviction
EOF

cat > "${RENDERED}/redis-cache.conf" << EOF
port 6380
bind 127.0.0.1
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}
appendonly yes
maxmemory 512mb
maxmemory-policy allkeys-lru
EOF

cat > "${RENDERED}/redis-replica.conf" << EOF
port 6381
bind 127.0.0.1
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}
appendonly yes
replicaof 127.0.0.1 6380
maxmemory 512mb
maxmemory-policy allkeys-lru
EOF

# ── nats: config-file auth (replaces --auth argv). The container runs as
# uid 65534 (nobody) — the file must be owned/readable by exactly that uid.
cat > "${RENDERED}/nats-server.conf" << EOF
authorization {
  token = "${NATS_TOKEN}"
}
EOF
chown 65534:65534 "${RENDERED}/nats-server.conf"
chmod 400 "${RENDERED}/nats-server.conf"

# ── pg-exporter: DSN file (image-native DATA_SOURCE_NAME_FILE) ──────────────
cat > "${RENDERED}/pg-exporter-dsn.txt" << EOF
postgresql://${PG_USERNAME}:${PG_PASSWORD}@pgpool-ha:5432/${PG_DATABASE}?sslmode=disable
EOF

# ── sentinels: keep mounted confs authoritative (apply_redis_auth.sh) ───────
bash "${ROOT_DIR}/infra/deploy/scripts/apply_redis_auth.sh" >/dev/null

chown 999:999 "${RENDERED}/redis-queue.conf" "${RENDERED}/redis-cache.conf" "${RENDERED}/redis-replica.conf"
chmod 400 "${RENDERED}/redis-queue.conf" "${RENDERED}/redis-cache.conf" "${RENDERED}/redis-replica.conf"
umask 022
echo "✅ render-secrets: freeradius/redis/nats/pg-exporter secret files rendered to ${RENDERED} (0600)"
