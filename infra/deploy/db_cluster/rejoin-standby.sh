#!/bin/bash
# rejoin-standby.sh — resync a detached / old-primary PG node back as a
# standby of the CURRENT primary.
#
# WHY: pgpool's failover.sh promotes the standby but the old primary, once
# it restarts, is still a PRIMARY (no auto-rejoin). Two primaries = split-
# brain. The watchdog alerts; this script performs the deliberate, manual fix.
#
# WHAT IT DOES: destroys ONLY the target node's local data volume and re-
# clones it from the live primary via Bitnami's replication bootstrap
# (pg_basebackup). The current primary is never touched. If the target is
# already a healthy standby, nothing happens.
#
# Usage:  sudo bash rejoin-standby.sh [pg-0|pg-1] [--yes]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=/var/log/pgpool_failover.log
log() { echo "[$(date)] rejoin: $1" | tee -a "$LOG"; }

[ -f "$SCRIPT_DIR/.env" ] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }

TARGET="${1:-}"
ASSUME_YES="${2:-}"
case "$TARGET" in
    pg-0) VOL=db_cluster_pg_0_data; MODE_VAR=PG0_REPL_MODE; HOST_VAR=PG0_MASTER_HOST ;;
    pg-1) VOL=db_cluster_pg_1_data; MODE_VAR=PG1_REPL_MODE; HOST_VAR=PG1_MASTER_HOST ;;
    *) echo "Usage: sudo bash $0 [pg-0|pg-1] [--yes]"; exit 1 ;;
esac

role() { # role <container> -> f(primary) | t(standby) | ""
    docker exec -e PGPASSWORD="${PG_PASSWORD:-}" "$1" psql -h 127.0.0.1 \
        -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" \
        -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d '[:space:]'
}

P0=$(role pg-0); P1=$(role pg-1)
# pgpool's view of who is primary decides the resync source
PRIMARY=$(docker exec pg-pgpool psql -h 127.0.0.1 -p 5432 -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" -tAc \
    "SHOW pool_nodes" 2>/dev/null | awk -F'|' '$7=="primary"{gsub(/ /,"",$2); print $2}')

if [ -z "$PRIMARY" ]; then
    log "ABORT: no healthy primary visible to pgpool - fix the primary first."
    exit 1
fi
[ "$TARGET" = "$PRIMARY" ] && { log "ABORT: $TARGET is the current primary."; exit 1; }

TROLE=$([ "$TARGET" = "pg-0" ] && echo "$P0" || echo "$P1")
if [ "$TROLE" = "t" ]; then
    # An in-recovery node can still be BROKEN: its walreceiver may be dead
    # (e.g. timeline divergence after an old promote — "highest timeline N of
    # the primary is behind recovery timeline N+1"). Treat "not streaming
    # right now" as needing a rejoin instead of a false NOTHING-TO-DO.
    STATUS=$(docker exec -e PGPASSWORD="${PG_PASSWORD:-}" "$TARGET" psql -h 127.0.0.1 \
        -U "${PG_USERNAME:-rnd_user}" -d "${PG_DATABASE:-rnd_db}" -tAc \
        "SELECT status FROM pg_stat_wal_receiver" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ "$STATUS" = "streaming" ]; then
        log "NOTHING TO DO: $TARGET is already a streaming standby of $PRIMARY."
        exit 0
    fi
    log "BROKEN STANDBY: $TARGET is in recovery but its walreceiver is '$STATUS' (not streaming) — rejoin needed."
fi
log "REJOIN NEEDED: $TARGET is '$([ "$TROLE" = "f" ] && echo primary || echo down/broken)' while pgpool primary is $PRIMARY."

if [ "$ASSUME_YES" != "--yes" ]; then
    printf "This will WIPE %s volume '%s' and re-clone it from %s. Type REJOIN to continue: " "$TARGET" "$VOL" "$PRIMARY"
    read -r A
    [ "$A" = "REJOIN" ] || { echo "Aborted."; exit 1; }
fi

log "Stopping $TARGET ..."
docker stop "$TARGET" >/dev/null
docker rm -f "$TARGET" >/dev/null 2>&1 || true
log "Wiping volume $VOL ..."
docker volume rm "$VOL" >/dev/null || { log "ABORT: could not remove $VOL"; exit 1; }

log "Re-creating $TARGET as slave of $PRIMARY ..."
cd "$SCRIPT_DIR"
export "$MODE_VAR=slave" "$HOST_VAR=$PRIMARY"
docker compose up -d "$TARGET" >> "$LOG" 2>&1 || { log "ERROR: compose up failed for $TARGET"; exit 1; }

log "Waiting for replication bootstrap on $TARGET ..."
for i in $(seq 1 60); do
    R=$(role "$TARGET")
    if [ "$R" = "t" ]; then
        log "SUCCESS: $TARGET is now a standby of $PRIMARY. (pgpool/watchdog will re-attach it.)"
        exit 0
    fi
    sleep 5
done
log "WARN: $TARGET not in recovery yet after 300s - check 'docker logs $TARGET'."
exit 1