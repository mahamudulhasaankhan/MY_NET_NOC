#!/usr/bin/env bash
# ==============================================================================
# MY_NET NOC — Derived Environment Renderer
# Renders EVERY per-stack env file and secret-bearing config from the single
# canonical store (/etc/nms/nms.env). The derived files are build artifacts:
# never edit them by hand — rotate a secret in the central store (nms-secrets)
# and re-run this script, then recreate/restart the affected services.
# All outputs are chmod 600 and gitignored.
# ==============================================================================
set -euo pipefail

NMS_ENV="${NMS_ENV:-/etc/nms/nms.env}"
[ -r "${NMS_ENV}" ] || { echo "FATAL: ${NMS_ENV} not readable — run setup.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "${NMS_ENV}"; set +a
# Repo root: explicit override > NMS_REPO recorded in the central store >
# three levels up from this script (infra/deploy/scripts → repo root).
ROOT_DIR="${NMS_ROOT_DIR:-${NMS_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}}"
STACK_ENV="${ROOT_DIR}/infra/deploy/nms_stack/.env"
CLUSTER_ENV="${ROOT_DIR}/infra/deploy/db_cluster/.env"

# ── helpers ──────────────────────────────────────────────────────────────────
# resolve VAR: central store value, else the value currently present in the
# existing target file (carried over so a partial central store is healed),
# else a freshly generated secret that is ALSO appended to the central store
# so it never diverges again.
resolve() { # resolve <var> <existing-file> <generator>
    local var="$1" file="$2" gen="$3" cur="" old=""
    cur="$(grep -E "^${var}=" "${NMS_ENV}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    if [ -z "${cur}" ] && [ -f "${file}" ]; then
        old="$(grep -E "^${var}=" "${file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        if [ -n "${old}" ]; then
            cur="${old}"
            printf '%s=%s\n' "${var}" "${old}" >> "${NMS_ENV}"
            chmod 600 "${NMS_ENV}"
            echo "  [carry-over] ${var} -> central store" >&2
        fi
    fi
    if [ -z "${cur}" ]; then
        cur="$(${gen})"
        printf '%s=%s\n' "${var}" "${cur}" >> "${NMS_ENV}"
        chmod 600 "${NMS_ENV}"
        echo "  [generated]  ${var} -> central store" >&2
    fi
    printf '%s' "${cur}"
}

gen_hex16() { openssl rand -hex 16; }
gen_hex24() { openssl rand -hex 24; }
gen_b64()   { openssl rand -base64 24 | tr -d '/+=' | head -c 32; }

# ── required values ──────────────────────────────────────────────────────────
# STRUCTURAL identifiers — always canonical, never resolved/generated:
PG_USERNAME="rnd_user"
PG_DATABASE="rnd_db"

PG_PASSWORD="$(resolve PG_PASSWORD "${CLUSTER_ENV}" gen_hex16)"
PG_REPL_USER="${PG_REPL_USER:-replicator}"
PG_REPL_PASSWORD="$(resolve PG_REPL_PASSWORD "${CLUSTER_ENV}" gen_hex16)"
PG_POSTGRES_PASSWORD="$(resolve PG_POSTGRES_PASSWORD "${CLUSTER_ENV}" gen_hex16)"
PGPOOL_PCP_PASSWORD="$(resolve PGPOOL_PCP_PASSWORD "${CLUSTER_ENV}" gen_hex16)"
REDIS_PASSWORD="$(resolve REDIS_PASSWORD "${STACK_ENV}" gen_hex16)"
NATS_TOKEN="$(resolve NATS_TOKEN "${STACK_ENV}" gen_hex24)"
CLICKHOUSE_PASSWORD="$(resolve CLICKHOUSE_PASSWORD "${STACK_ENV}" gen_hex16)"
RADIUS_NAS_SECRET="$(resolve RADIUS_NAS_SECRET "${STACK_ENV}" gen_hex16)"
DBGATE_ADMIN_PASSWORD="$(resolve DBGATE_ADMIN_PASSWORD "${STACK_ENV}" gen_b64)"

# ── render db_cluster/.env ───────────────────────────────────────────────────
mkdir -p "$(dirname "${CLUSTER_ENV}")"
umask 077
cat > "${CLUSTER_ENV}" << EOF
# RENDERED by render-envs.sh from /etc/nms/nms.env — do not edit by hand.
PG_USERNAME=${PG_USERNAME}
PG_DATABASE=${PG_DATABASE}
PG_PASSWORD=${PG_PASSWORD}
PG_REPL_USER=${PG_REPL_USER}
PG_REPL_PASSWORD=${PG_REPL_PASSWORD}
PG_POSTGRES_PASSWORD=${PG_POSTGRES_PASSWORD}
PGPOOL_PCP_PASSWORD=${PGPOOL_PCP_PASSWORD}
EOF
chmod 600 "${CLUSTER_ENV}"

# ── render nms_stack/.env ────────────────────────────────────────────────────
mkdir -p "$(dirname "${STACK_ENV}")"
cat > "${STACK_ENV}" << EOF
# RENDERED by render-envs.sh from /etc/nms/nms.env — do not edit by hand.
PG_USERNAME=${PG_USERNAME}
PG_DATABASE=${PG_DATABASE}
PG_PASSWORD=${PG_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
NATS_TOKEN=${NATS_TOKEN}
CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}
RADIUS_NAS_SECRET=${RADIUS_NAS_SECRET}
DBGATE_ADMIN_PASSWORD=${DBGATE_ADMIN_PASSWORD}
EOF
chmod 600 "${STACK_ENV}"
umask 022

# ── render remaining secret-bearing configs ─────────────────────────────────
SCRIPTS_DIR="$(dirname "${BASH_SOURCE[0]}")"
[ -x "${SCRIPTS_DIR}/apply_secrets.sh" ] && bash "${SCRIPTS_DIR}/apply_secrets.sh" || true
[ -x "${SCRIPTS_DIR}/apply_redis_auth.sh" ] && bash "${SCRIPTS_DIR}/apply_redis_auth.sh" || true
[ -x "${SCRIPTS_DIR}/render-secrets-files.sh" ] && bash "${SCRIPTS_DIR}/render-secrets-files.sh" || true

echo "✅ render-envs: db_cluster/.env + nms_stack/.env rendered from ${NMS_ENV}"
echo "   Recreate affected containers (docker compose up -d --force-recreate) to apply changes."
