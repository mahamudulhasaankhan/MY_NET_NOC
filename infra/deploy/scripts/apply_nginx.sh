#!/bin/bash
# ══════════════════════════════════════════════════════════
# apply_nginx.sh v3 — unified, idempotent, conflict-free
#   • Sources /etc/nms/nginx_vars.env (single customization point)
#   • Auto-generates self-signed TLS cert with CN+SAN=<IP>
#   • Preserves existing .htpasswd unless REGEN_BASIC_AUTH=1
#   • Auto-rollback on nginx -t failure
# ══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${NMS_REPO:-}" ]; then
    NMS_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

VARS_FILE="/etc/nms/nginx_vars.env"
if [ ! -f "$VARS_FILE" ]; then
    echo "[nginx] ERROR: $VARS_FILE not found."
    echo "[nginx] Run setup.sh first (it creates the file) or create it manually:"
    echo '  NMS_HOST=10.10.10.50'
    echo '  TLS_MODE=selfsigned'
    exit 1
fi
set -a; source "$VARS_FILE"; set +a

NMS_HOST="${NMS_HOST:?NMS_HOST required in $VARS_FILE}"
TLS_MODE="${TLS_MODE:-selfsigned}"
SSL_DIR=/etc/nginx/ssl
mkdir -p "$SSL_DIR"

# ── TLS certificate provisioning ──────────────────────────────────────────
if [ "$TLS_MODE" = "selfsigned" ]; then
    if [ ! -f "$SSL_DIR/nms.key" ] || [ ! -f "$SSL_DIR/nms_chain.crt" ] \
       || ! openssl x509 -in "$SSL_DIR/nms_chain.crt" -noout -checkhost "$NMS_HOST" >/dev/null 2>&1; then
        echo "[nginx] Generating self-signed cert (CN+SAN=$NMS_HOST, 10yr)…"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$SSL_DIR/nms.key" -out "$SSL_DIR/nms_chain.crt" \
            -subj "/C=BD/ST=Dhaka/O=MY_NET NOC/CN=$NMS_HOST" \
            -addext "subjectAltName=IP:$NMS_HOST" \
            -addext "keyUsage=digitalSignature,keyEncipherment" \
            -addext "extendedKeyUsage=serverAuth" 2>/dev/null
        chmod 600 "$SSL_DIR/nms.key"
    fi
elif [ "$TLS_MODE" = "provided" ]; then
    echo "[nginx] TLS_MODE=provided — using $TLS_CERT_FILE + $TLS_KEY_FILE"
    # Skip copy when paths already point at the live files (same-file guard)
    if [ "$(readlink -f "$TLS_CERT_FILE")" != "$(readlink -f "$SSL_DIR/nms_chain.crt")" ]; then
        cp "$TLS_CERT_FILE" "$SSL_DIR/nms_chain.crt"
        chmod 600 "$SSL_DIR/nms.key" 2>/dev/null || true
    fi
    [ -f "$TLS_KEY_FILE" ] && [ "$(readlink -f "$TLS_KEY_FILE")" != "$(readlink -f "$SSL_DIR/nms.key")" ] && {
        cp "$TLS_KEY_FILE" "$SSL_DIR/nms.key"; chmod 600 "$SSL_DIR/nms.key";
    } || true
fi

if [ ! -f "$SSL_DIR/dhparam.pem" ]; then
    echo "[nginx] Generating dhparam 2048 (-dsaparam fast mode)…"
    openssl dhparam -dsaparam -out "$SSL_DIR/dhparam.pem" 2048 2>/dev/null
fi

# ── Basic-auth (preserve existing unless REGEN requested) ────────────────
if [[ "${REGEN_BASIC_AUTH:-0}" == "1" || ! -f /etc/nginx/.htpasswd ]]; then
    if [ -n "${BASIC_AUTH_PASS:-}" ]; then
        printf "%s:%s\n" "${BASIC_AUTH_USER:-admin}" "$(openssl passwd -apr1 "$BASIC_AUTH_PASS")" > /etc/nginx/.htpasswd
        chmod 600 /etc/nginx/.htpasswd
        echo "[nginx] Basic-auth credentials written."
    else
        # auto-generate strong password once, print it
        GEN_PASS=$(openssl rand -base64 15)
        printf "%s:%s\n" "${BASIC_AUTH_USER:-admin}" "$(openssl passwd -apr1 "$GEN_PASS")" > /etc/nginx/.htpasswd
        chmod 600 /etc/nginx/.htpasswd
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " 🔑 BASIC-AUTH (save this!): ${BASIC_AUTH_USER:-admin} / $GEN_PASS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
fi

# ── Render template ───────────────────────────────────────────────────────
cp -f "$NMS_REPO/infra/deploy/nginx/waf-rules.conf" /etc/nginx/waf-rules.conf
cp -f "$NMS_REPO/infra/deploy/nginx/performance.conf" /etc/nginx/conf.d/performance.conf
cp -f "$NMS_REPO/infra/deploy/nginx/engine_upstream.conf" /etc/nginx/conf.d/engine_upstream.conf

# Backup current rendered config for rollback
[ -f /etc/nginx/sites-available/nms_proxy ] && cp /etc/nginx/sites-available/nms_proxy /tmp/nms_proxy.bak

sed -e "s|{{APP_ROOT}}|$NMS_REPO|g" -e "s|{{NMS_HOST}}|$NMS_HOST|g" \
    "$NMS_REPO/infra/deploy/nginx/nms_proxy.template" > /etc/nginx/sites-available/nms_proxy

if nginx -t 2>/tmp/nginx_test_err; then
    systemctl reload nginx
    echo "[nginx] Configuration applied & reloaded successfully ✅"
else
    echo "[nginx] ❌ Config test FAILED — rolling back!"
    if [ -f /tmp/nms_proxy.bak ]; then
        cp /tmp/nms_proxy.bak /etc/nginx/sites-available/nms_proxy
        nginx -t && systemctl reload nginx
        echo "[nginx] Rollback complete."
    fi
    cat /tmp/nginx_test_err
    exit 1
fi
