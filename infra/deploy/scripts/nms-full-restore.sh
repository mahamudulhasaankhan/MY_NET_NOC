#!/usr/bin/env bash
set -u
BACKUP_FILE="${1:-}"
PASSWORD=""
ROOT_DIR=""
shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --password) PASSWORD="$2"; shift 2 ;;
        --root)     ROOT_DIR="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done
[[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]] || { echo "FATAL: backup file not found"; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "FATAL: run as root"; exit 1; }
if [[ -z "$ROOT_DIR" ]] && [[ -f /etc/nms/nms.env ]]; then
    ROOT_DIR="$(grep -E '^NMS_REPO=' /etc/nms/nms.env 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
[[ -n "$ROOT_DIR" && -d "$ROOT_DIR" ]] || { echo "FATAL: ROOT_DIR not found (pass --root)"; exit 1; }
if [[ -z "$PASSWORD" ]]; then
    read -r -s -p "Backup decryption password: " PASSWORD; echo
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { echo "[$(date '+%H:%M:%S')] $*"; }
log "Decrypting backup..."
openssl enc -d -aes-256-cbc -in "$BACKUP_FILE" -out "$WORK/archive.tar.gz" -pass "pass:${PASSWORD}" -pbkdf2 2>/dev/null || { echo "FATAL: decryption failed (wrong password?)"; exit 1; }
log "Extracting..."
mkdir -p "$WORK/x"; tar xzf "$WORK/archive.tar.gz" -C "$WORK/x"
cd "$WORK/x"
log "Verifying checksums..."
( cd "$WORK/x" && sha256sum -c sha256sums.txt >/dev/null 2>&1 ) && log "  checksums OK" || log "  WARN: checksum mismatch"
log "Stopping services & containers..."
systemctl stop nms_engine@{8000..8004} nms_worker@{9000..9002} nms_watchdog.timer 2>/dev/null || true
if [[ -d "$ROOT_DIR/infra/deploy/db_cluster" ]]; then
    ( cd "$ROOT_DIR/infra/deploy/db_cluster" && docker compose down 2>/dev/null || true )
fi
if [[ -d "$ROOT_DIR/infra/deploy/nms_stack" ]]; then
    ( cd "$ROOT_DIR/infra/deploy/nms_stack" && docker compose down 2>/dev/null || true )
fi
log "Restoring /etc/nms (secrets)..."
rm -rf /etc/nms
mkdir -p /etc/nms
cp -a etc_nms/. /etc/nms/
chmod 700 /etc/nms; chmod 600 /etc/nms/nms.env 2>/dev/null || true
if grep -q '^NMS_REPO=' /etc/nms/nms.env; then
    sed -i "s|^NMS_REPO=.*|NMS_REPO=${ROOT_DIR}|" /etc/nms/nms.env
else
    echo "NMS_REPO=${ROOT_DIR}" >> /etc/nms/nms.env
fi
log "Restoring nginx ssl/auth/sites..."
mkdir -p /etc/nginx/ssl
cp -f nginx_ssl/* /etc/nginx/ssl/ 2>/dev/null || true
[[ -f nginx_ssl/htpasswd ]] && cp -f nginx_ssl/htpasswd /etc/nginx/.htpasswd
mkdir -p /etc/nginx/sites-enabled
cp -f nginx_sites/* /etc/nginx/sites-enabled/ 2>/dev/null || true
log "Restoring systemd units..."
cp -f systemd/nms_engine@.service /etc/systemd/system/ 2>/dev/null || true
cp -f systemd/nms_worker@.service /etc/systemd/system/ 2>/dev/null || true
cp -f systemd/nms_watchdog.service /etc/systemd/system/ 2>/dev/null || true
cp -f systemd/nms_watchdog.timer /etc/systemd/system/ 2>/dev/null || true
rm -rf /etc/systemd/system/nms_engine@.service.d /etc/systemd/system/nms_worker@.service.d
cp -a systemd/nms_engine@.service.d /etc/systemd/system/ 2>/dev/null || true
cp -a systemd/nms_worker@.service.d /etc/systemd/system/ 2>/dev/null || true
log "Restoring helpers & static..."
for f in helpers/*; do [[ -f "$f" ]] && cp -f "$f" /usr/local/bin/; done
rm -rf /usr/local/bin/static; mkdir -p /usr/local/bin/static
cp -a static/. /usr/local/bin/static/ 2>/dev/null || true
cp -f sudoers/* /etc/sudoers.d/ 2>/dev/null || true
chmod 440 /etc/sudoers.d/nms-* 2>/dev/null || true
cp -f sysctl/* /etc/sysctl.d/ 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true
log "Re-rendering derived env files..."
bash "$ROOT_DIR/infra/deploy/scripts/render-envs.sh" 2>/dev/null || true
bash "$ROOT_DIR/infra/deploy/scripts/apply_secrets.sh" 2>/dev/null || true
bash "$ROOT_DIR/infra/deploy/scripts/apply_redis_auth.sh" 2>/dev/null || true

if command -v docker >/dev/null 2>&1; then
    log "Starting db_cluster..."
    ( cd "$ROOT_DIR/infra/deploy/db_cluster" && docker compose up -d 2>/dev/null || true )
    for i in $(seq 1 30); do
        docker exec pg-pgpool pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break
        sleep 2
    done
    if [[ -f db/rnd_db.dump ]]; then
        log "Restoring PostgreSQL dump..."
        set -a; . /etc/nms/nms.env; set +a
        PRIMARY=$(docker exec pg-pgpool psql -h 127.0.0.1 -p 5432 -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" -tAc "SHOW pool_nodes" 2>/dev/null | awk -F'|' '$7=="primary"{print $2}')
        case "$PRIMARY" in pg-0) PPORT=15432;; pg-1) PPORT=25432;; *) PPORT=6432 ;; esac
        docker exec -e PGPASSWORD="${PG_PASSWORD:-}" "pg-${PRIMARY:-pg-0}" psql -U postgres -c "DROP DATABASE IF EXISTS ${PG_DATABASE:-rnd_db};" 2>/dev/null || true
        docker exec -e PGPASSWORD="${PG_PASSWORD:-}" "pg-${PRIMARY:-pg-0}" psql -U postgres -c "CREATE DATABASE ${PG_DATABASE:-rnd_db} OWNER ${PG_USERNAME:-rnd_user};" 2>/dev/null || true
        pg_restore -h 127.0.0.1 -p "${PPORT}" -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" --no-owner db/rnd_db.dump 2>/dev/null && log "  pg_restore OK" || log "  WARN: pg_restore had errors"
    fi
    if [[ -f db/clickhouse_schema.sql ]]; then
        log "Restoring ClickHouse schema..."
        CH_PASS="${CLICKHOUSE_PASSWORD:-}"
        curl -s -m 60 "http://127.0.0.1:8123/" --user "default:${CH_PASS}" --data-binary @db/clickhouse_schema.sql >/dev/null 2>&1 || true
    fi
    if [[ -f db/redis_dump.rdb ]]; then
        log "Restoring Redis RDB..."
        RCONT=$(docker ps --format '{{.Names}}' | grep redis | head -1)
        docker cp db/redis_dump.rdb "${RCONT}:/data/dump.rdb" 2>/dev/null || true
        docker restart "$RCONT" >/dev/null 2>&1 || true
    fi
    if [[ -d volumes ]]; then
        log "Restoring docker volumes..."
        for vol in volumes/*.tar.gz; do
            [[ -f "$vol" ]] || continue
            vname=$(basename "$vol" .tar.gz)
            docker volume create "$vname" >/dev/null 2>&1 || true
            docker run --rm -v "${vname}:/data" -v "$WORK/x/volumes:/backup" alpine tar xzf "/backup/$(basename "$vol")" -C /data 2>/dev/null || true
        done
    fi
    log "Starting nms_stack..."
    ( cd "$ROOT_DIR/infra/deploy/nms_stack" && docker compose up -d 2>/dev/null || true )
fi
log "Restarting services..."
systemctl daemon-reload
systemctl enable nms_watchdog.timer 2>/dev/null || true
systemctl start nms_watchdog.timer 2>/dev/null || true
for p in 8000 8001 8002 8003 8004; do systemctl restart "nms_engine@${p}" 2>/dev/null || true; done
for p in 9000 9001 9002; do systemctl restart "nms_worker@${p}" 2>/dev/null || true; done
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
log "Running verify-install.sh..."
if [[ -x /usr/local/bin/verify-install.sh ]]; then
    /usr/local/bin/verify-install.sh || log "  WARN: verify-install reported issues"
fi
echo "======================================================================"
echo "  RESTORE COMPLETE"
echo "  Open: https://$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "======================================================================"
