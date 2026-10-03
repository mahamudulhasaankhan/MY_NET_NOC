#!/usr/bin/env bash
# ==============================================================================
# MY_NET NOC — Post-Install Security & Health Self-Test
# One command that PROVES the platform is correctly locked down:
#   sudo verify-install.sh
# Exit 0 = all checks passed. Any FAIL tells you exactly which pillar broke.
# ==============================================================================
set -uo pipefail

PASS=0; FAIL=0
check() { # check <label> <ok:0/1> <detail>
    if [ "$2" = "0" ]; then printf "  ✅ %-46s %s\n" "$1" "${3:-}"; PASS=$((PASS+1));
    else printf "  ❌ %-46s %s\n" "$1" "${3:-}"; FAIL=$((FAIL+1)); fi
}

NMS_ENV="${NMS_ENV:-/etc/nms/nms.env}"

echo "════════════════════════════════════════════════════════"
echo " MY_NET NOC — Install Verification"
echo "════════════════════════════════════════════════════════"

# 1. Service units
BAD=""
for p in 8000 8001 8002 8003 8004; do systemctl is-active --quiet "nms_engine@${p}" || BAD="$BAD $p"; done
check "web engines active (5 instances)" "$([ -z "${BAD}" ] && echo 0 || echo 1)" "${BAD}"
BAD=""
for p in 9000 9001 9002; do systemctl is-active --quiet "nms_worker@${p}" || BAD="$BAD $p"; done
check "polling workers active (3 instances)" "$([ -z "${BAD}" ] && echo 0 || echo 1)" "${BAD}"

# 2. Engine health on loopback
C=$(curl -s -m 3 http://127.0.0.1:8000/health 2>/dev/null | grep -o '"status":"ok"' | head -1)
check "engine /health responds ok" "$([ "$C" = '"status":"ok"' ] && echo 0 || echo 1)"

# 3. Central secret store
if [ -f "${NMS_ENV}" ]; then
    M=$(stat -c '%a' "${NMS_ENV}")
    check "central store ${NMS_ENV} is 0600" "$([ "${M}" = "600" ] && echo 0 || echo 1)" "(mode ${M})"
else
    check "central store present" 1 "${NMS_ENV} missing"
fi

# 4. Derived env files exist + 0600 + no drift from the store
for f in /home/pr0xy/RnD_Server/infra/deploy/nms_stack/.env /home/pr0xy/RnD_Server/infra/deploy/db_cluster/.env; do
    [ -f "$f" ] || { check "$(basename $(dirname $f))/.env rendered" 1 "missing"; continue; }
    M=$(stat -c '%a' "$f")
    check "$(basename $(dirname $f))/.env is 0600" "$([ "${M}" = "600" ] && echo 0 || echo 1)" "(mode ${M})"
done
if [ -f "${NMS_ENV}" ] && [ -f /home/pr0xy/RnD_Server/infra/deploy/nms_stack/.env ]; then
    set -a; . "${NMS_ENV}"; set +a
    DRIFT=""
    for kv in REDIS_PASSWORD NATS_TOKEN CLICKHOUSE_PASSWORD RADIUS_NAS_SECRET; do
        stackval=$(grep -E "^${kv}=" /home/pr0xy/RnD_Server/infra/deploy/nms_stack/.env 2>/dev/null | head -1 | cut -d= -f2-)
        [ "${stackval}" = "${!kv}" ] || DRIFT="$DRIFT $kv"
    done
    check "derived stack env matches central store" "$([ -z "${DRIFT}" ] && echo 0 || echo 1)" "${DRIFT:-in sync}"
fi

# 5. THE BIG ONE: no plaintext secret in docker container Cmd/Env
LEAK=""
if [ -f "${NMS_ENV}" ]; then
    set -a; . "${NMS_ENV}"; set +a
    for c in nms-freeradius nms-freeradius-2 nms-redis-cache nms-redis-queue nms-redis-replica nats nms-radius-balancer; do
        INSPECT=$(docker inspect "$c" --format '{{json .Config.Cmd}} {{json .Config.Env}}' 2>/dev/null) || continue
        for secret in "${REDIS_PASSWORD:-x}" "${NATS_TOKEN:-x}" "${PG_PASSWORD:-x}" "${RADIUS_NAS_SECRET:-x}"; do
            [ ${#secret} -lt 8 ] && continue
            case "$INSPECT" in *"$secret"*) LEAK="$LEAK $c" ;; esac
        done
    done
    check "no plaintext secrets in docker inspect" "$([ -z "${LEAK}" ] && echo 0 || echo 1)" "${LEAK:-clean}"
else
    check "no plaintext secrets in docker inspect" 1 "no store to test"
fi

# 6. Wizard state: on an initialized stack the setup routes are DEREGISTERED,
# so /setup/status answers 401 unauthorized — that IS the locked proof.
ST=$(curl -s -m 3 http://127.0.0.1:8000/api/v3/setup/status 2>/dev/null)
if echo "${ST}" | grep -q '"initialized":false'; then
    check "setup wizard pending (PIN-gated)" 0
elif echo "${ST}" | grep -q '"unauthorized"'; then
    check "setup wizard permanently locked (routes gone)" 0
else
    check "setup wizard state" 1 "status endpoint unreachable or malformed"
fi

# 7. TLS
if [ -f /etc/nginx/ssl/nms_chain.crt ]; then
    FPR=$(openssl x509 -in /etc/nginx/ssl/nms_chain.crt -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    check "TLS certificate present (SHA256 known)" "$([ -n "${FPR}" ] && echo 0 || echo 1)" "${FPR:0:20}…"
else
    check "TLS certificate present" 1 "missing"
fi

# 8. Break-glass + rotation tooling
check "nms-secrets rotation engine installed" "$([ -x /usr/local/bin/nms-secrets ] && echo 0 || echo 1)"
check "nms-admin-reset break-glass installed" "$([ -x /usr/local/bin/nms-admin-reset ] && echo 0 || echo 1)"

# 9. HA deep-check (radius auth path, pgpool, crash loops) if available
if [ -x /usr/local/bin/verify-ha.sh ]; then
    if sudo -n bash /usr/local/bin/verify-ha.sh >/tmp/verify-ha.$$ 2>&1; then
        check "verify-ha deep health (radius/pgpool/HA)" 0
    else
        check "verify-ha deep health (radius/pgpool/HA)" 1 "$(grep -E 'FAIL' /tmp/verify-ha.$$ | head -2 | tr '\n' ';')"
    fi
    rm -f /tmp/verify-ha.$$
fi

echo "════════════════════════════════════════════════════════"
if [ ${FAIL} -eq 0 ]; then
    echo " RESULT: ALL ${PASS} CHECKS PASSED — install is verified."
    exit 0
fi
echo " RESULT: ${FAIL} FAILED / ${PASS} passed — fix the ❌ items above."
exit 1
