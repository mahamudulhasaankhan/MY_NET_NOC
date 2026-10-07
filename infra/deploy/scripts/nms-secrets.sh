#!/usr/bin/env bash
# ==============================================================================
# MY_NET NOC — Secret Rotation Engine (nms-secrets)
# The SINGLE mechanism for changing any service credential:
#   * the Initialize Wizard calls `set` via sudo during first-run setup
#   * operators call `rotate` later (generates a strong random value)
# Every path: validate -> update central store (/etc/nms/nms.env) ->
# re-render derived files (render-envs.sh) -> restart the affected services.
# New values arrive on STDIN (never argv — ps-safe) or via --from-file.
# ==============================================================================
set -euo pipefail

NMS_ENV="${NMS_ENV:-/etc/nms/nms.env}"
# Repo root: NMS_REPO recorded in the central store wins (survives any
# install location); fall back to the documented default.
ROOT_DIR="${NMS_ROOT_DIR:-$(grep -E '^NMS_REPO=' "${NMS_ENV}" 2>/dev/null | head -1 | cut -d= -f2-)}"
ROOT_DIR="${ROOT_DIR:-/home/pr0xy/RnD_Server}"
STACK_DIR="${ROOT_DIR}/infra/deploy/nms_stack"
CLUSTER_DIR="${ROOT_DIR}/infra/deploy/db_cluster"
WEB_PORTS=(8000 8001 8002 8003 8004)
WORKER_PORTS=(9000 9001 9002)

log()  { echo "[nms-secrets] $*"; }
fail() { echo "[nms-secrets] FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root (via sudo)"

update_store() { # update_store KEY VALUE
    local key="$1" val="$2"
    touch "${NMS_ENV}"; chmod 600 "${NMS_ENV}"
    if grep -qE "^${key}=" "${NMS_ENV}"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "${NMS_ENV}"
    else
        printf '%s=%s\n' "${key}" "${val}" >> "${NMS_ENV}"
    fi
}

read_stdin_value() {
    local v
    v="$(cat)"
    v="${v%$'\n'}"
    [ -n "$v" ] || fail "empty value on stdin"
    [ ${#v} -ge 12 ] || fail "value too short (minimum 12 characters)"
    case "$v" in *[$'\n\r']*) fail "newlines not allowed" ;; esac
    printf '%s' "$v"
}

restart_engines() {
    # Only meaningful once the wizard is closed; harmless otherwise.
    for p in "${WEB_PORTS[@]}";  do systemctl try-restart "nms_engine@${p}.service"  2>/dev/null || true; done
    for p in "${WORKER_PORTS[@]}"; do systemctl try-restart "nms_worker@${p}.service" 2>/dev/null || true; done
    log "engine + worker instances restarted with the new environment"
}

escape_sql() { printf '%s' "$1" | sed "s/'/''/g"; }

# ── per-service appliers ─────────────────────────────────────────────────────
apply_db() { # $1 = new rnd_user password
    local new="$1" old_url escaped
    old_url="$(grep -E '^DATABASE_URL=' "${NMS_ENV}" | head -1 | cut -d= -f2-)"
    [ -n "${old_url}" ] || fail "DATABASE_URL missing — cannot reach the DB"
    escaped="$(printf '%s' "${new}" | sed "s/'/''/g")"
    # 1) change the role (old sessions keep working; new ones need the new pw)
    PGPASSWORD="" psql "${old_url}" -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE rnd_user WITH PASSWORD '${escaped}'" >/dev/null
    # 2) central store + derived files
    update_store PG_PASSWORD "${new}"
    update_store DATABASE_URL  "postgres://rnd_user:${new}@127.0.0.1:6432/rnd_db?sslmode=disable"
    update_store MIGRATION_DATABASE_URL "postgres://rnd_user:${new}@127.0.0.1:6432/rnd_db?sslmode=disable"
    bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" >/dev/null
    # 3) EVERY consumer of PG_PASSWORD: pgpool re-derives pool_passwd, the
    #    freeradius backends re-render their sql connection, pg-exporter
    #    rebuilds its data source.
    (cd "${CLUSTER_DIR}" && docker compose up -d --force-recreate pgpool pgpool-2 pgpool-proxy >/dev/null 2>&1)
    (cd "${STACK_DIR}" && docker compose up -d --force-recreate freeradius freeradius-2 pg-exporter >/dev/null 2>&1)
    restart_engines
    log "db: rnd_user password rotated; pgpool + freeradius + pg-exporter recreated; engines restarted"
}

apply_redis() {
    update_store REDIS_PASSWORD "$1"
    bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" >/dev/null
    (cd "${STACK_DIR}" && docker compose up -d --force-recreate redis-cache redis-queue redis-replica redis-sentinel-1 redis-sentinel-2 redis-sentinel-3 redis_exporter >/dev/null 2>&1)
    restart_engines
    log "redis: cache/queue/replica + sentinels + exporter recreated; engines restarted"
}

apply_nats() {
    update_store NATS_TOKEN "$1"
    # The deployed NATS_URL embeds the token (nats://<token>@host:port) —
    # update it too, or the engines keep authenticating with the old one.
    OLD_URL="$(grep -E '^NATS_URL=' "${NMS_ENV}" | head -1 | cut -d= -f2-)"
    if [ -n "${OLD_URL}" ]; then
        NEW_URL="$(printf '%s' "${OLD_URL}" | sed -E "s|^nats://[^@]*@|nats://${1}@|")"
        [ "${NEW_URL}" != "${OLD_URL}" ] && update_store NATS_URL "${NEW_URL}"
    fi
    bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" >/dev/null
    (cd "${STACK_DIR}" && docker compose up -d --force-recreate nats >/dev/null 2>&1)
    restart_engines
    log "nats: token rotated (incl. embedded NATS_URL); container recreated; engines restarted"
}

apply_clickhouse() {
    update_store CLICKHOUSE_PASSWORD "$1"
    update_store GRAFANA_CH_PASSWORD "$1"
    bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" >/dev/null
    (cd "${STACK_DIR}" && docker compose up -d --force-recreate clickhouse >/dev/null 2>&1)
    restart_engines
    log "clickhouse: password XML re-rendered; container recreated; engines restarted"
}

apply_radius() {
    update_store RADIUS_NAS_SECRET "$1"
    bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" >/dev/null
    (cd "${STACK_DIR}" && docker compose up -d --force-recreate freeradius freeradius-2 radius-balancer >/dev/null 2>&1)
    restart_engines
    log "radius: secret rotated; freeradius + balancer recreated; engines restarted"
    log "WARNING: field NAS devices hold the old shared secret — update them too"
}

apply_dbgate() {
    update_store DBGATE_ADMIN_PASSWORD "$1"
    bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" >/dev/null
    (cd "${STACK_DIR}" && docker compose up -d --force-recreate dbgate >/dev/null 2>&1)
    log "dbgate: admin password rotated; container recreated"
}

apply_webhook() {
    update_store SHEETS_WEBHOOK_SECRET "$1"
    restart_engines
    log "webhook: SHEETS_WEBHOOK_SECRET rotated; engines restarted (update the Google Apps Script header)"
}

apply_backup() {
    update_store BACKUP_PASSWORD "$1"
    log "backup: future archives encrypted with the new password (old archives need the old one)"
}

# ── rotation safety: snapshot → apply → health gate → rollback ──────────────
SNAP_DIR="/var/backups/nms/secrets"
HEALTH_URL="http://127.0.0.1:8000/health"

# Encrypted snapshot of every secret file BEFORE touching anything. Old
# snapshots beyond the newest 10 are pruned. Failure to snapshot ABORTS the
# rotation — never change credentials without a way back.
snapshot_secrets() {
    local ts dir tar snap_pass
    snap_pass="$(grep -E '^BACKUP_PASSWORD=' "${NMS_ENV}" 2>/dev/null | head -1 | cut -d= -f2-)"
    snap_pass="${snap_pass:-$(grep -E '^SECRET_KEY=' "${NMS_ENV}" 2>/dev/null | head -1 | cut -d= -f2-)}"
    ts="$(date +%Y%m%d-%H%M%S)"
    dir="$(mktemp -d)"
    chmod 700 "${dir}"
    cp "${NMS_ENV}" "${dir}/nms.env"
    [ -f "${STACK_DIR}/.env" ]   && cp "${STACK_DIR}/.env"   "${dir}/nms_stack.env"
    [ -f "${CLUSTER_DIR}/.env" ] && cp "${CLUSTER_DIR}/.env" "${dir}/db_cluster.env"
    mkdir -p "${SNAP_DIR}"
    tar -C "${dir}" -czf "${dir}/bundle.tar" nms.env nms_stack.env db_cluster.env 2>/dev/null \
        || tar -C "${dir}" -czf "${dir}/bundle.tar" nms.env
    openssl enc -aes-256-cbc -salt -pbkdf2 \
        -in "${dir}/bundle.tar" -out "${SNAP_DIR}/secrets-${ts}.enc" \
        -pass "pass:${snap_pass}" 2>/dev/null
    chmod 600 "${SNAP_DIR}/secrets-${ts}.enc" 2>/dev/null || true
    rm -rf "${dir}"
    ls -1t "${SNAP_DIR}"/secrets-*.enc 2>/dev/null | tail -n +11 | xargs -r rm -f
    SNAP_FILE="${SNAP_DIR}/secrets-${ts}.enc"
    log "snapshot: ${SNAP_FILE}"
}

# Restore the pre-rotation files, re-render, restart — the way back.
rollback_secrets() {
    local dir snap_pass
    snap_pass="$(grep -E '^BACKUP_PASSWORD=' "${NMS_ENV}" 2>/dev/null | head -1 | cut -d= -f2-)"
    snap_pass="${snap_pass:-$(grep -E '^SECRET_KEY=' "${NMS_ENV}" 2>/dev/null | head -1 | cut -d= -f2-)}"
    dir="$(mktemp -d)"; chmod 700 "${dir}"
    openssl enc -d -aes-256-cbc -pbkdf2 -in "${SNAP_FILE}" \
        -pass "pass:${BACKUP_PASSWORD:-${SECRET_KEY}}" -out "${dir}/bundle.tar" 2>/dev/null \
        && tar -C "${dir}" -xzf "${dir}/bundle.tar" 2>/dev/null
    [ -f "${dir}/nms.env" ]        && cp "${dir}/nms.env" "${NMS_ENV}"        && chmod 600 "${NMS_ENV}"
    [ -f "${dir}/nms_stack.env" ]  && cp "${dir}/nms_stack.env" "${STACK_DIR}/.env" && chmod 600 "${STACK_DIR}/.env"
    [ -f "${dir}/db_cluster.env" ] && cp "${dir}/db_cluster.env" "${CLUSTER_DIR}/.env" && chmod 600 "${CLUSTER_DIR}/.env"
    rm -rf "${dir}"
    bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" >/dev/null 2>&1
    restart_engines
    log "ROLLED BACK to the pre-rotation snapshot (${SNAP_FILE})"
}

# After apply+restart: engines must come back healthy within 90s, else roll back.
health_gate() {
    local ok=0 i
    for i in $(seq 1 18); do
        sleep 5
        if curl -s -m 3 "${HEALTH_URL}" 2>/dev/null | grep -q '"status":"ok"'; then ok=1; break; fi
    done
    if [ ${ok} -ne 1 ]; then
        log "health gate FAILED after rotation — rolling back"
        rollback_secrets
        fail "rotation rolled back: engines did not come back healthy"
    fi
    log "health gate passed — engines healthy with the new credential"
}

apply_pgadmin() { # postgres superuser — admin/maintenance role only
    local new="$1" su_pass escaped
    # Self-rotation: the superuser changes its own password, connecting
    # DIRECTLY to the primary (pg-0) with the current superuser password.
    su_pass="$(grep -E '^PG_POSTGRES_PASSWORD=' "${CLUSTER_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "${su_pass}" ] || fail "PG_POSTGRES_PASSWORD missing — cannot authenticate to the primary"
    escaped="$(printf '%s' "${new}" | sed "s/'/''/g")"
    PGPASSWORD="${su_pass}" PGCONNECT_TIMEOUT=10 psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE postgres WITH PASSWORD '${escaped}'" >/dev/null
    update_store PG_POSTGRES_PASSWORD "${new}"
    bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" >/dev/null
    log "pgadmin: postgres superuser password rotated (no service restart needed)"
}

apply_repl() { # replication role — pg-1 standby re-attaches with the new password
    local new="$1" escaped repl_user su_pass
    repl_user="$(grep -E '^PG_REPL_USER=' "${NMS_ENV}" 2>/dev/null | head -1 | cut -d= -f2-)"
    repl_user="${repl_user:-repl_user}"
    # rnd_user cannot ALTER other roles — use the postgres superuser.
    su_pass="$(grep -E '^PG_POSTGRES_PASSWORD=' "${CLUSTER_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "${su_pass}" ] || fail "PG_POSTGRES_PASSWORD missing — cannot authenticate to the primary"
    escaped="$(printf '%s' "${new}" | sed "s/'/''/g")"
    PGPASSWORD="${su_pass}" PGCONNECT_TIMEOUT=10 psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE ${repl_user} WITH PASSWORD '${escaped}'" >/dev/null
    update_store PG_REPL_PASSWORD "${new}"
    bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh" >/dev/null
    (cd "${CLUSTER_DIR}" && docker compose up -d --force-recreate --pull never --no-deps pg-1 >/dev/null 2>&1)
    sleep 20
    local st
    st="$(PGPASSWORD="" psql "${old_url}" -tAc "SELECT state FROM pg_stat_replication LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
    [ "${st}" = "streaming" ] || fail "replication not streaming after repl rotation (state: ${st:-none})"
    log "repl: replicator password rotated; pg-1 re-attached, replication streaming"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
[ -r "${NMS_ENV}" ] || fail "${NMS_ENV} missing — run setup.sh first"

cmd="${1:-}"; svc="${2:-}"
case "${cmd}" in
    set)
        [ -n "${svc}" ] || fail "usage: nms-secrets set <service>  (value on stdin)"
        if [ "${3:-}" = "--from-file" ] && [ -n "${4:-}" ]; then
            VALUE="$(cat "${4}")"
        else
            VALUE="$(read_stdin_value)"
        fi
        ;;
    rotate)
        [ -n "${svc}" ] || fail "usage: nms-secrets rotate <service>"
        VALUE="$(openssl rand -hex 16)"
        ;;
    render)
        bash "${ROOT_DIR}/infra/deploy/scripts/render-envs.sh"
        exit 0
        ;;
    restart-engines)
        restart_engines
        exit 0
        ;;
    *) fail "usage: nms-secrets {set|rotate} <db|redis|nats|clickhouse|radius|dbgate|backup|pgadmin|repl|webhook> | render | restart-engines" ;;
esac

snapshot_secrets
case "${svc}" in
    db)          apply_db "${VALUE}"; health_gate ;;
    redis)       apply_redis "${VALUE}"; health_gate ;;
    nats)        apply_nats "${VALUE}"; health_gate ;;
    clickhouse)  apply_clickhouse "${VALUE}"; health_gate ;;
    radius)      apply_radius "${VALUE}"; health_gate ;;
    dbgate)      apply_dbgate "${VALUE}" ;;
    backup)      apply_backup "${VALUE}" ;;
    pgadmin)     apply_pgadmin "${VALUE}" ;;
    repl)        apply_repl "${VALUE}" ;;
    webhook)     apply_webhook "${VALUE}" ;;
    *) fail "unknown service '${svc}' (db|redis|nats|clickhouse|radius|dbgate|backup|pgadmin|repl)" ;;
esac
log "done: ${svc}"
