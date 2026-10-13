#!/bin/bash
# drill-restore.sh — proves the LATEST nightly backup actually restores.
# Runs monthly via nms_drill.timer. Spins a throwaway postgres:18-alpine,
# restores the newest rnd_db.dump, compares table & radcheck counts against
# the live DB, reports to log + Telegram, always cleans up after itself.
set -uo pipefail

LOG=/var/log/nms_drill.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

[ -r /etc/nms/nms.env ] && { set -a; . /etc/nms/nms.env; set +a; }

get_tg_creds() {
    if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT:-}" ]; then return; fi
    local out
    out=$(psql "${DATABASE_URL:-}" -tAc "SELECT value FROM settings WHERE key='telegram_token'" 2>/dev/null)
    [ -n "$out" ] && TELEGRAM_TOKEN="$out"
    out=$(psql "${DATABASE_URL:-}" -tAc "SELECT value FROM settings WHERE key='telegram_chat_id'" 2>/dev/null)
    [ -n "$out" ] && TELEGRAM_CHAT="$out"
}
get_tg_creds
tg() { [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT:-}" ] && \
    curl -s -m 10 "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT}" -d "text=$1" -d "parse_mode=HTML" >/dev/null 2>&1 || true; }

WORK=/tmp/nms_drill_$$
NAME="nms_drill_$$"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

NEWEST=$(ls -t /var/backups/nms/nms_backup_*.tar.gz 2>/dev/null | head -1)
if [ -z "$NEWEST" ]; then
    log "FAIL: no backup archive found"; tg "🚨 <b>NMS Restore-Drill FAILED</b>: no backup archive exists!"; exit 1
fi
AGE_H=$(( ($(date +%s) - $(stat -c %Y "$NEWEST")) / 3600 ))
log "Drill start: $(basename "$NEWEST") (${AGE_H}h old)"

mkdir -p "$WORK"
if ! tar xzf "$NEWEST" -C "$WORK" 2>>"$LOG"; then
    log "FAIL: archive unreadable/corrupt"; tg "🚨 <b>NMS Restore-Drill FAILED</b>: latest archive is corrupt"; exit 1
fi
[ -s "$WORK/rnd_db.dump" ] || { log "FAIL: rnd_db.dump missing in archive"; tg "🚨 <b>NMS Restore-Drill FAILED</b>: dump missing"; exit 1; }

docker run -d --name "$NAME" -e POSTGRES_PASSWORD=drill postgres:18-alpine >/dev/null 2>&1 || \
    { log "FAIL: cannot start drill container"; tg "🚨 <b>NMS Restore-Drill FAILED</b>: container start error"; exit 1; }
OK=1
for i in $(seq 1 30); do docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; [ "$i" = 30 ] && OK=0; done
[ "$OK" = 1 ] || { log "FAIL: drill postgres not ready"; tg "🚨 <b>NMS Restore-Drill FAILED</b>: pg not ready"; exit 1; }

docker exec -i "$NAME" pg_restore -U postgres -d postgres --no-owner --no-privileges \
    < "$WORK/rnd_db.dump" > "$WORK/restore.log" 2>&1
HARD=$(grep -cE '^pg_restore: error' "$WORK/restore.log" 2>/dev/null)
[ -z "$HARD" ] && HARD=0
D_TBL=$(docker exec "$NAME" psql -U postgres -d postgres -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public'" 2>/dev/null)
D_RAD=$(docker exec "$NAME" psql -U postgres -d postgres -tAc "SELECT count(*) FROM radcheck" 2>/dev/null)
# Live counts go through the pooler-2 container (standby pooler) via the
# front-door proxy: independent of whichever pooler currently owns failover.
L_TBL=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" pg-pgpool-2 psql -h pgpool-ha -p 5432 -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" \
    -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public'" 2>/dev/null)
L_RAD=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" pg-pgpool-2 psql -h pgpool-ha -p 5432 -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" \
    -tAc "SELECT count(*) FROM radcheck" 2>/dev/null)

if [ "$HARD" -eq 0 ] && [ -n "$D_TBL" ] && [ "$D_TBL" = "$L_TBL" ] && [ "$D_RAD" = "$L_RAD" ]; then
    log "PASS: restore OK — tables $D_TBL/$L_TBL, radcheck $D_RAD/$L_RAD (source: $(basename "$NEWEST"))"
    tg "✅ <b>NMS Restore-Drill PASSED</b>: tables <code>$D_TBL/$L_TBL</code>, radcheck <code>$D_RAD/$L_RAD</code> — nightly backup is VERIFIED restorable"
    exit 0
else
    log "FAIL: restore errors=$HARD, tables drill=$D_TBL live=$L_TBL, radcheck drill=$D_RAD live=$L_RAD"
    tg "🚨 <b>NMS Restore-Drill FAILED</b>: tables <code>$D_TBL/$L_TBL</code>, radcheck <code>$D_RAD/$L_RAD</code>, errors=$HARD"
    exit 1
fi