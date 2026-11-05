#!/usr/bin/env bash
set -u
OUT_DIR="/var/backups/nms"
PASSWORD=""
INCLUDE_VOLUMES=0
TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="nms_full_${TS}.tar.gz"
ENC="nms_full_${TS}.tar.gz.enc"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)             OUT_DIR="$2"; shift 2 ;;
        --password)        PASSWORD="$2"; shift 2 ;;
        --include-volumes) INCLUDE_VOLUMES=1; shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "FATAL: run as root"; exit 1; }
mkdir -p "$OUT_DIR"
if [[ -z "$PASSWORD" ]] && [[ -r /etc/nms/nms.env ]]; then
    set -a; . /etc/nms/nms.env; set +a
    PASSWORD="${BACKUP_PASSWORD:-${ENCRYPTION_KEY:-}}"
fi
if [[ -z "$PASSWORD" ]]; then
    read -r -s -p "Backup encryption password: " PASSWORD; echo
fi
[[ -n "$PASSWORD" ]] || { echo "FATAL: password required"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p etc_nms nginx_ssl nginx_sites systemd helpers static volumes db varlib_nms uploads sudoers sysctl
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a /var/log/nms_backup.log; }
mkdir -p /var/log
log "Capturing /etc/nms ..."
cp -a /etc/nms/. etc_nms/ 2>/dev/null || true
log "Capturing nginx ..."
cp -a /etc/nginx/ssl/. nginx_ssl/ 2>/dev/null || true
cp -f /etc/nginx/.htpasswd nginx_ssl/htpasswd 2>/dev/null || true
for d in /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d; do
    [[ -d "$d" ]] && find "$d" -maxdepth 1 -type f \( -iname '*nms*' -o -iname '*my_net*' \) -exec cp {} nginx_sites/ \; 2>/dev/null
done
log "Capturing systemd ..."
cp -f /etc/systemd/system/nms_engine@.service /etc/systemd/system/nms_worker@.service systemd/ 2>/dev/null || true
cp -f /etc/systemd/system/nms_watchdog.service /etc/systemd/system/nms_watchdog.timer systemd/ 2>/dev/null || true
cp -a /etc/systemd/system/nms_engine@.service.d systemd/ 2>/dev/null || true
cp -a /etc/systemd/system/nms_worker@.service.d systemd/ 2>/dev/null || true
log "Capturing helpers ..."
for f in /usr/local/bin/nms*; do [[ -f "$f" ]] && cp -f "$f" helpers/; done
cp -a /usr/local/bin/static/. static/ 2>/dev/null || true
cp -f /etc/sudoers.d/nms-* sudoers/ 2>/dev/null || true
cp -f /etc/sysctl.d/99-nms* sysctl/ 2>/dev/null || true
if [[ -r /etc/nms/nms.env ]]; then
    set -a; . /etc/nms/nms.env; set +a
    ROOT="${NMS_REPO:-}"
    if [[ -n "$ROOT" && -d "$ROOT/.git" ]]; then
        echo "$ROOT" > source_meta.txt
        git -C "$ROOT" rev-parse HEAD > source_commit.txt 2>/dev/null || true
        git -C "$ROOT" remote get-url origin > source_remote.txt 2>/dev/null || true
    fi
fi
cp -a /var/lib/nms/. varlib_nms/ 2>/dev/null || true

if command -v docker >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a /var/log/nms_backup.log; }
    log "Dumping PostgreSQL ..."
    if docker ps --format '{{.Names}}' | grep -q '^pg-'; then
        PRIMARY=$(docker exec pg-pgpool psql -h 127.0.0.1 -p 5432 -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" -tAc "SHOW pool_nodes" 2>/dev/null | awk -F'|' '$7=="primary"{print $2}')
        case "$PRIMARY" in pg-0) PPORT=15432;; pg-1) PPORT=25432;; *) PPORT=6432 ;; esac
        DUMP_URL="postgresql://localhost:${PPORT}/${PG_DATABASE:-rnd_db}?sslmode=disable&user=${PG_USERNAME:-rnd_user}&password=${PG_PASSWORD:-}"
        pg_dump "$DUMP_URL" -Fc -f db/rnd_db.dump 2>/dev/null && log "  pg_dump OK" || log "  WARN: pg_dump failed"
    fi
    log "Dumping ClickHouse ..."
    if docker ps --format '{{.Names}}' | grep -q clickhouse; then
        CH_PASS="${CLICKHOUSE_PASSWORD:-}"
        if command -v clickhouse-client >/dev/null 2>&1; then
            clickhouse-client --host 127.0.0.1 --port 9000 -u default --password "$CH_PASS" --query "SELECT name FROM system.databases WHERE name NOT IN ('system','INFORMATION_SCHEMA','information_schema')" 2>/dev/null | while read -r db; do
                clickhouse-client --host 127.0.0.1 --port 9000 -u default --password "$CH_PASS" --query "SHOW CREATE DATABASE ${db}" >> db/clickhouse_schema.sql 2>/dev/null
                for t in $(clickhouse-client --host 127.0.0.1 --port 9000 -u default --password "$CH_PASS" --query "SHOW TABLES FROM ${db}" 2>/dev/null); do
                    clickhouse-client --host 127.0.0.1 --port 9000 -u default --password "$CH_PASS" --query "SELECT * FROM ${db}.${t} FORMAT Native" > "db/ch_${db}_${t}.native" 2>/dev/null || true
                done
            done
            log "  clickhouse dump done"
        else
            log "  WARN: clickhouse-client not available"
        fi
    fi
    log "Saving Redis RDB ..."
    if docker ps --format '{{.Names}}' | grep -q redis; then
        RCONT=$(docker ps --format '{{.Names}}' | grep redis | head -1)
        docker exec "$RCONT" redis-cli -a "${REDIS_PASSWORD:-}" --no-auth-warning BGSAVE >/dev/null 2>&1 || true
        sleep 2
        docker cp "${RCONT}:/data/dump.rdb" db/redis_dump.rdb 2>/dev/null && log "  redis rdb OK" || log "  WARN: redis rdb failed"
    fi
    if [[ $INCLUDE_VOLUMES -eq 1 ]]; then
        log "Archiving docker volumes (raw) ..."
        mkdir -p volumes
        for vol in $(docker volume ls -q | grep -iE 'portainer|gitea|nms|upload|grafana'); do
            docker run --rm -v "${vol}:/data" -v "$WORK/volumes:/backup" alpine tar czf "/backup/${vol}.tar.gz" -C /data . 2>/dev/null || true
        done
        mv "$WORK/volumes"/* volumes/ 2>/dev/null || true
    fi
fi
mkdir -p uploads; cp -a /home/*/uploads/. uploads/ 2>/dev/null || true
cp -a /usr/local/bin/static/dist/. uploads/dist/ 2>/dev/null || true
log "Generating manifest & checksums ..."
find . -type f ! -name "sha256sums.txt" -print0 | sort -z | xargs -0 sha256sum > sha256sums.txt
cat > manifest.json <<EOF
{
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "include_volumes": $INCLUDE_VOLUMES,
  "files": $(find . -type f | wc -l)
}
EOF
log "Encrypting archive ..."
tar czf "/tmp/${ARCHIVE}" -C "$WORK" .
openssl enc -aes-256-cbc -salt -in "/tmp/${ARCHIVE}" -out "${OUT_DIR}/${ENC}" -pass "pass:${PASSWORD}" -pbkdf2
rm -f "/tmp/${ARCHIVE}"
chmod 600 "${OUT_DIR}/${ENC}"
SIZE=$(du -h "${OUT_DIR}/${ENC}" 2>/dev/null | cut -f1)
log "Backup complete: ${OUT_DIR}/${ENC} (${SIZE})"
echo ""
echo "======================================================================"
echo "  BACKUP FILE : ${OUT_DIR}/${ENC}"
echo "  PASSWORD    : (store it safely - required for restore)"
echo "  RESTORE     : sudo nms-full-restore.sh ${OUT_DIR}/${ENC} --password '...'"
echo "======================================================================"
