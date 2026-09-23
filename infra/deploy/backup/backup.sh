#!/bin/bash
set -e
trap 'echo "[ERROR] $0 failed at line $LINENO" | tee -a /var/log/nms_backup.log; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${NMS_REPO:-}" ]; then
    NMS_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/backups/nms"
LOG_FILE="/var/log/nms_backup.log"

# Host-level config (NMS_REPO, TELEGRAM_UPLOAD, CLICKHOUSE_* etc.)
if [ -r /etc/nms/nms.env ]; then
    set -a; . /etc/nms/nms.env; set +a
fi

if [ -z "${DATABASE_URL:-}" ]; then
    if [ -f "$NMS_REPO/.env" ]; then
        set -a; . "$NMS_REPO/.env"; set +a
    fi
    if [ -z "${PG_USERNAME:-}" ] || [ -z "${PG_PASSWORD:-}" ] || [ -z "${PG_DATABASE:-}" ]; then
        echo "[ERROR] DATABASE_URL (or PG_USERNAME/PG_PASSWORD/PG_DATABASE) is required" | tee -a /var/log/nms_backup.log
        exit 1
    fi
    DATABASE_URL="postgresql://localhost:6432/${PG_DATABASE}?sslmode=disable&user=${PG_USERNAME}&password=${PG_PASSWORD}"
fi

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"
log "Starting backup"

# Boot-race guard: after a VM reboot the catch-up timer can fire before the
# database containers are listening. Wait up to 5 minutes for a working DB.
DB_WAIT=0
until psql "${DATABASE_URL}" -tAc "SELECT 1" >/dev/null 2>&1; do
    DB_WAIT=$((DB_WAIT + 10))
    if [ "$DB_WAIT" -ge 300 ]; then
        log "ERROR: database not reachable after ${DB_WAIT}s - aborting (will retry tomorrow)"
        rm -rf "$WORK_DIR"
        exit 1
    fi
    log "DB not ready yet, waiting (${DB_WAIT}s)..."
    sleep 10
done
log "Database ready (waited ${DB_WAIT}s)"

DB_FILE="rnd_db.dump"
# pg_dump must read from exactly ONE node. Through the pooler, statement-level
# load balancing could scatter the dump's queries between primary and standby
# and yield a logically inconsistent archive. Resolve the CURRENT primary via
# the pooler (works after failovers) and dump from that node's published port.
DUMP_URL="$DATABASE_URL"
PRIMARY_NODE=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" pg-pgpool psql -h 127.0.0.1 -p 5432 \
    -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" -tAc "SHOW pool_nodes" 2>/dev/null \
    | awk -F'|' '$7=="primary"{print $2}' || true)
case "$PRIMARY_NODE" in
    pg-0) PPORT=15432 ;;
    pg-1) PPORT=25432 ;;
    *)    PPORT="" ;;
esac
if [ -n "$PPORT" ]; then
    DUMP_URL="postgresql://localhost:${PPORT}/${PG_DATABASE:-rnd_db}?sslmode=disable&user=${PG_USERNAME:-rnd_user}&password=${PG_PASSWORD:-}"
    log "Primary node is $PRIMARY_NODE - dumping via 127.0.0.1:$PPORT"
else
    log "WARN: could not resolve the primary node - dumping via the pooler (DATABASE_URL)"
fi
pg_dump "$DUMP_URL" -Fc -f "$DB_FILE" > /dev/null 2>> "$LOG_FILE"
log "Database dump completed"

mkdir -p engine_backup
cp $NMS_REPO/backend/*.go engine_backup/ 2>/dev/null || true
cp $NMS_REPO/backend/nms_engine engine_backup/ 2>/dev/null || true
log "Engine files copied"

mkdir -p frontend_dist
cp -r $NMS_REPO/frontend/dist/* frontend_dist/ 2>/dev/null || true
log "Frontend files copied"

# ClickHouse backup (raw telemetry tables: netflow/sflow/radius/syslog).
# Uses BACKUP ... TO File inside the container, then copies it out.
CH_ENV="$NMS_REPO/infra/deploy/nms_stack/.env"
if [ -r "$CH_ENV" ]; then
    CH_PASSWORD=$(grep -E '^CLICKHOUSE_PASSWORD=' "$CH_ENV" | head -1 | cut -d= -f2-)
    CH_TS=$(date +%Y%m%d_%H%M%S)
    if docker exec nms-clickhouse clickhouse-client --password "$CH_PASSWORD" \
        --query "BACKUP DATABASE default TO File('/var/lib/clickhouse/backups/ch_${CH_TS}')" \
        >> "$LOG_FILE" 2>&1; then
        mkdir -p clickhouse_backup
        docker cp "nms-clickhouse:/var/lib/clickhouse/backups/ch_${CH_TS}" clickhouse_backup/ > /dev/null 2>> "$LOG_FILE"
        docker exec nms-clickhouse rm -rf "/var/lib/clickhouse/backups/ch_${CH_TS}" 2>/dev/null || true
        log "ClickHouse backup completed: ch_${CH_TS}"
        # Integrity check: per-table count.txt sum in the backup must match
        # live count(). Catches corrupt/truncated parts (e.g. write races
        # during mutations) that silently produce unreadable backups.
        CH_OK=1
        for tbl in netflow_raw sflow_raw radius_acct_raw syslog_raw; do
            LIVE=$(docker exec nms-clickhouse clickhouse-client --password "$CH_PASSWORD" \
                -q "SELECT count() FROM default.$tbl" 2>/dev/null || echo "ERR")
            BACK=$(find "clickhouse_backup/ch_${CH_TS}/data/default/$tbl" -name count.txt \
                -exec cat {} + 2>/dev/null | awk '{s+=$1} END{print s+0}')
            if [ "$LIVE" != "$BACK" ]; then
                log "WARN: CH integrity mismatch $tbl (live=$LIVE backup=$BACK)"
                CH_OK=0
            fi
        done
        [ "$CH_OK" = "1" ] && log "ClickHouse backup integrity OK" || log "WARN: CH backup integrity check failed (see above)"
    else
        log "WARN: ClickHouse backup failed (continuing with other components)"
    fi
else
    log "WARN: $CH_ENV not readable - skipping ClickHouse backup"
fi

# VictoriaMetrics backup: atomic snapshot -> copy out -> delete snapshot.
# VM holds router time-series (CPU/bandwidth/PPPoE) with NO other backup;
# a corrupted volume would lose all history (same class of risk as the
# redis-cache AOF corruption incident).
VM_SNAP=$(curl -s -m 10 -X POST "http://127.0.0.1:8428/snapshot/create" 2>/dev/null | grep -oE '"snapshot":"[^"]+"' | cut -d'"' -f4)
if [ -n "$VM_SNAP" ]; then
    mkdir -p vm_backup
    # docker cp breaks on VM snapshot symlinks - stream a tar from inside the container
    if docker exec nms-victoriametrics tar czf - -C /victoria-metrics-data/snapshots "$VM_SNAP" \
        > "vm_backup/vm_snapshot_${TIMESTAMP}.tar.gz" 2>> "$LOG_FILE" && [ -s "vm_backup/vm_snapshot_${TIMESTAMP}.tar.gz" ]; then
        log "VictoriaMetrics snapshot copied: $VM_SNAP"
    else
        log "WARN: VictoriaMetrics snapshot copy failed"
    fi
    curl -s -m 10 -X POST "http://127.0.0.1:8428/snapshot/delete?snapshot=$VM_SNAP" >/dev/null 2>&1
else
    log "WARN: VictoriaMetrics snapshot create failed - skipping VM backup"
fi

ARCHIVE="nms_backup_${TIMESTAMP}.tar.gz"
tar -czf "$BACKUP_DIR/$ARCHIVE" -C "$WORK_DIR" . > /dev/null 2>> "$LOG_FILE"
chmod 600 "$BACKUP_DIR/$ARCHIVE"
log "Archive created: $ARCHIVE"

# Offsite copy: Telegram (opt-in via TELEGRAM_UPLOAD=1).
# Creds come from the PG settings table (same source as telegram-relay).
# Chunks split at 49MB (Telegram 50MB document limit); local archive kept.
TG_POST_URL="https://api.telegram.org/bot"
if [ "${TELEGRAM_UPLOAD:-0}" = "1" ]; then
    TG_TOKEN=""
    TG_CHAT=""
    if [ -n "${DATABASE_URL:-}" ]; then
        TG_TOKEN=$(psql "$DATABASE_URL" -t -A -c "SELECT value FROM settings WHERE key='telegram_token'" 2>/dev/null)
        TG_CHAT=$(psql "$DATABASE_URL" -t -A -c "SELECT value FROM settings WHERE key='telegram_chat_id'" 2>/dev/null)
    fi
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        UPLOAD_DIR="$WORK_DIR/telegram_upload"
        mkdir -p "$UPLOAD_DIR"
        ENC_ARCHIVE="${ARCHIVE}.enc"
        if [ -n "${BACKUP_PASSWORD:-}" ]; then
            log "Encrypting backup with AES-256-CBC for Telegram upload"
            # Using -pbkdf2 is recommended for openssl 1.1.1+
            openssl enc -aes-256-cbc -salt -in "$BACKUP_DIR/$ARCHIVE" -out "$WORK_DIR/$ENC_ARCHIVE" -pass "pass:$BACKUP_PASSWORD" -pbkdf2 >/dev/null 2>&1
        else
            log "WARN: BACKUP_PASSWORD not set, falling back to ENCRYPTION_KEY"
            openssl enc -aes-256-cbc -salt -in "$BACKUP_DIR/$ARCHIVE" -out "$WORK_DIR/$ENC_ARCHIVE" -pass "pass:$ENCRYPTION_KEY" -pbkdf2 >/dev/null 2>&1
        fi

        SIZE_MB=$(stat -c %s "$WORK_DIR/$ENC_ARCHIVE" | awk '{print int($1/1024/1024)}')
        if [ "$SIZE_MB" -gt 49 ]; then
            split -b 49M "$WORK_DIR/$ENC_ARCHIVE" "$UPLOAD_DIR/${ENC_ARCHIVE}.part_"
        else
            cp "$WORK_DIR/$ENC_ARCHIVE" "$UPLOAD_DIR/$ENC_ARCHIVE"
        fi
        CHUNKS=$(ls "$UPLOAD_DIR" | wc -l)
        log "Telegram offsite upload starting (${CHUNKS} chunk(s), ${SIZE_MB}MB, ENCRYPTED)"
        TG_OK=1
        for f in "$UPLOAD_DIR"/*; do
            if ! curl -s -m 300 -F "chat_id=$TG_CHAT" -F "document=@$f" \
                "${TG_POST_URL}${TG_TOKEN}/sendDocument" | grep -q '"ok":true'; then
                log "WARN: Telegram chunk upload failed: $(basename "$f")"
                TG_OK=0
            fi
        done
        if [ "$TG_OK" = "1" ]; then
            log "Telegram offsite upload OK (${CHUNKS} chunk(s))"
            curl -s -m 20 -F "chat_id=$TG_CHAT" -F "text=NMS nightly encrypted backup uploaded: $ENC_ARCHIVE (${CHUNKS} chunk(s), ${SIZE_MB}MB)" \
                "${TG_POST_URL}${TG_TOKEN}/sendMessage" >/dev/null 2>&1 || true
        else
            log "WARN: Telegram offsite upload incomplete"
        fi
    else
        log "WARN: TELEGRAM_UPLOAD=1 but telegram_token/chat_id not found in settings - skipping"
    fi
fi

# ---------------------------------------------------------------------------
# Optional S3/R2 offsite sync (zero-config until R2_REMOTE is set).
# Add to /etc/nms/nms.env once the bucket exists:
#   R2_REMOTE=r2:nms-backups        (rclone remote:name, see RUNBOOK "R2")
# Requires: apt install rclone && rclone config (Cloudflare R2 = S3-compatible).
# Keeps the same 14-day lifecycle locally; server-side lifecycle rules should
# expire objects older than 30d in the bucket itself.
if [ -n "${R2_REMOTE:-}" ] && command -v rclone >/dev/null 2>&1; then
    log "R2 offsite sync starting -> ${R2_REMOTE}"
    if rclone copy "$BACKUP_DIR" "$R2_REMOTE" --max-age 48h --transfers 2 --checkers 4 >/dev/null 2>&1; then
        log "R2 offsite sync OK"
        curl -s -m 20 -F "chat_id=$TG_CHAT" -F "text=NMS backup synced offsite to R2" \
            "${TG_POST_URL}${TG_TOKEN}/sendMessage" >/dev/null 2>&1 || true
    else
        log "WARN: R2 offsite sync FAILED (check rclone config/credentials)"
    fi
fi

find "$BACKUP_DIR" -name "nms_backup_*.tar.gz" -mtime +14 -delete 2>/dev/null || true
log "Old backups cleaned"

rm -rf "$WORK_DIR"
log "Backup completed successfully"
