#!/bin/bash
set -e
trap 'echo "[ERROR] $0 failed at line $LINENO"; exit 1' ERR

if [ $# -ne 1 ]; then
    echo "Usage: $0 <path-to-backup.tar.gz>"
    exit 1
fi

ARCHIVE="$1"
if [ ! -f "$ARCHIVE" ]; then
    echo "FAILURE: Backup file not found: $ARCHIVE"
    exit 1
fi

WORK_DIR=$(mktemp -d)

# Check if encrypted
if [[ "$ARCHIVE" == *.enc ]]; then
    echo "Encrypted archive detected. Decrypting..."
    if [ -z "${BACKUP_PASSWORD:-}" ] && [ -z "${ENCRYPTION_KEY:-}" ]; then
        echo "FAILURE: BACKUP_PASSWORD or ENCRYPTION_KEY must be set in environment to decrypt."
        exit 1
    fi
    PASS="${BACKUP_PASSWORD:-$ENCRYPTION_KEY}"
    DEC_ARCHIVE="$WORK_DIR/decrypted.tar.gz"
    openssl enc -d -aes-256-cbc -in "$ARCHIVE" -out "$DEC_ARCHIVE" -pass "pass:$PASS" -pbkdf2
    if [ $? -ne 0 ]; then
        echo "FAILURE: Decryption failed (wrong password?)"
        exit 1
    fi
    ARCHIVE="$DEC_ARCHIVE"
fi

echo "Extracting archive..."
tar -xzf "$ARCHIVE" -C "$WORK_DIR"
echo "SUCCESS: Archive extracted"

echo "Restoring database..."
if [ -f "$WORK_DIR/rnd_db.dump" ]; then
    if [ -z "${DATABASE_URL:-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -z "${NMS_REPO:-}" ]; then
            NMS_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
        fi
        if [ -f "$NMS_REPO/.env" ]; then
            set -a; . "$NMS_REPO/.env"; set +a
        fi
        if [ -z "${PG_USERNAME:-}" ] || [ -z "${PG_PASSWORD:-}" ] || [ -z "${PG_DATABASE:-}" ]; then
            echo "FAILURE: DATABASE_URL (or PG_USERNAME/PG_PASSWORD/PG_DATABASE) is required"
            exit 1
        fi
        DATABASE_URL="postgresql://localhost:15432/${PG_DATABASE}?sslmode=disable&user=${PG_USERNAME}&password=${PG_PASSWORD}"
    fi
    pg_restore --clean -d "$DATABASE_URL" "$WORK_DIR/rnd_db.dump" > /dev/null 2>&1
    echo "SUCCESS: Database restored"
else
    echo "FAILURE: Database dump not found in archive"
fi

echo "Restoring engine files..."
if [ -d "$WORK_DIR/engine_backup" ]; then
    rsync -a "$WORK_DIR/engine_backup/" "$NMS_REPO/backend/"
    echo "SUCCESS: Engine files restored"
else
    echo "FAILURE: Engine backup not found in archive"
fi

echo "Restoring frontend files..."
if [ -d "$WORK_DIR/frontend_dist" ]; then
    rsync -a "$WORK_DIR/frontend_dist/" "$NMS_REPO/frontend/dist/"
    echo "SUCCESS: Frontend files restored"
else
    echo "FAILURE: Frontend backup not found in archive"
fi

rm -rf "$WORK_DIR"
echo "Restore completed"
