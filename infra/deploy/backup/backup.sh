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
    DATABASE_URL="postgresql://localhost:5432/${PG_DATABASE}?sslmode=disable&user=${PG_USERNAME}&password=${PG_PASSWORD}"
fi

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"
log "Starting backup"

DB_FILE="rnd_db.dump"
pg_dump "$DATABASE_URL" -Fc -f "$DB_FILE" > /dev/null 2>> "$LOG_FILE"
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

find "$BACKUP_DIR" -name "nms_backup_*.tar.gz" -mtime +7 -delete 2>/dev/null || true
log "Old backups cleaned"

rm -rf "$WORK_DIR"
log "Backup completed successfully"
