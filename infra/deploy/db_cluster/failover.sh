#!/bin/sh
# pgpool failover_command: auto-promote the standby when the PRIMARY dies.
# Runs INSIDE the pgpool container (docker-static + docker.sock mounted).
# Args: $1=failed_node_id $2=failed_host $3=failed_port $4=old_primary_id $5=new_master_id
FAILED_ID="$1"
OLD_PRIMARY_ID="$4"
LOG=/var/log/pgpool_failover.log

echo "[$(date)] failover: failed=$1($2) old_primary=$4 new_master=$5" >> "$LOG"

if [ "$FAILED_ID" = "$OLD_PRIMARY_ID" ]; then
    # Safety guard: only promote if the "failed" primary is REALLY gone.
    # pgpool fires this on startup too (health-check race) while the primary
    # is perfectly healthy — promoting then causes a spurious timeline fork
    # (split-brain). Verify with pg_isready before touching anything.
    FAILED_HOST="$2"
    ATTEMPT=0
    while [ "$ATTEMPT" -lt 3 ]; do
        if docker-static exec "$FAILED_HOST" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
            echo "[$(date)] old primary $FAILED_HOST still answering pg_isready - NOT promoting (startup race)" >> "$LOG"
            exit 0
        fi
        ATTEMPT=$((ATTEMPT + 1))
        sleep 2
    done
    if [ "$FAILED_ID" = "0" ]; then
        PROMOTE_TARGET=pg-1
    else
        PROMOTE_TARGET=pg-0
    fi
    echo "[$(date)] primary died - promoting $PROMOTE_TARGET" >> "$LOG"
    docker-static exec "$PROMOTE_TARGET" pg_ctl promote -D /bitnami/postgresql/data >> "$LOG" 2>&1 \
        || echo "[$(date)] PROMOTE FAILED for $PROMOTE_TARGET" >> "$LOG"
else
    # Standby flap / health-check event — benign, no action. Not logged:
    # pgpool fires this on every health-check flap (dozens per incident).
    :
fi
exit 0
