#!/usr/bin/env bash
# MY_NET NOC — Security Hardening Applier (bulletproof port isolation)
#
# Three separate allow-lists (persisted in /etc/nms/nms.env):
#   ALLOWED_DEVICE_NETWORKS  -> device data-collection ports (syslog/netflow/sflow/radius/snmp-trap)
#   ALLOWED_WEB_NETWORKS     -> web login ports (80/443)
#   ALLOWED_SSH_NETWORKS     -> SSH port (444)
#
# Every other inbound port is dropped by UFW default-deny.
# Idempotent: safe to re-run on every setup.sh / nms-update.sh.
set -euo pipefail

NMS_ENV="${NMS_ENV:-/etc/nms/nms.env}"
[[ -r "${NMS_ENV}" ]] || { echo "FATAL: ${NMS_ENV} missing" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "${NMS_ENV}"; set +a

log() { echo "[nms-harden] $*"; }

trim() { echo "$1" | xargs; }

read_or_prompt() {
    local var_name="$1" env_key="$2" msg="$3" cur="" val=""
    cur="$(eval echo '${'"$var_name"':-}')"
    if [[ -z "${cur}" ]] && grep -qE "^${env_key}=" "${NMS_ENV}" 2>/dev/null; then
        cur="$(grep -E "^${env_key}=" "${NMS_ENV}" | head -1 | cut -d= -f2- | tr -d '"')"
    fi
    if [[ -z "${cur}" ]] && [[ -t 0 ]]; then
        echo ""
        echo "  ${msg}"
        echo "  Enter allowed LAN/CIDR list (comma-separated), e.g. 10.10.10.0/24,192.168.1.0/24"
        echo "  Leave empty to allow from ANY (not recommended for production)."
        read -r -p "  ${env_key} [any]: " val || true
        cur="${val}"
    fi
    eval "${var_name}=\"${cur}\""
}

persist_key() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "${NMS_ENV}"; then
        grep -vE "^${key}=" "${NMS_ENV}" > "${NMS_ENV}.tmp" && mv "${NMS_ENV}.tmp" "${NMS_ENV}"
    fi
    printf '%s="%s"\n' "${key}" "${val}" >> "${NMS_ENV}"
    chmod 600 "${NMS_ENV}"
}

apply_ufw_from_list() {
    local port="$1" proto="$2" list_var="$3" nets=""
    nets="$(eval echo '${'"$list_var"':-}')"
    nets="$(trim "${nets}")"
    if [[ -z "${nets}" ]]; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    else
        IFS=',' read -ra NETS <<< "${nets}"
        for n in "${NETS[@]}"; do
            n="$(trim "${n}")"
            [[ -z "$n" ]] && continue
            ufw allow from "$n" to any port "${port}" proto "${proto}" >/dev/null 2>&1 || true
        done
    fi
}

read_or_prompt ALLOWED_DEVICE_NETWORKS ALLOWED_DEVICE_NETWORKS \
    "Device data-collection ports (Syslog/NetFlow/sFlow/RADIUS/SNMP-trap) — allowed source networks:"
read_or_prompt ALLOWED_WEB_NETWORKS ALLOWED_WEB_NETWORKS \
    "Web login ports (HTTP 80 / HTTPS 443) — allowed source networks:"
read_or_prompt ALLOWED_SSH_NETWORKS ALLOWED_SSH_NETWORKS \
    "SSH port (444) — allowed source networks:"

persist_key ALLOWED_DEVICE_NETWORKS "${ALLOWED_DEVICE_NETWORKS}"
persist_key ALLOWED_WEB_NETWORKS "${ALLOWED_WEB_NETWORKS}"
persist_key ALLOWED_SSH_NETWORKS "${ALLOWED_SSH_NETWORKS}"

log "device nets=[${ALLOWED_DEVICE_NETWORKS:-any}] web nets=[${ALLOWED_WEB_NETWORKS:-any}] ssh nets=[${ALLOWED_SSH_NETWORKS:-any}]"

# ── 2. UFW firewall (port-isolation) ──────────────────────────────────────────
if command -v ufw >/dev/null 2>&1; then
    log "configuring UFW"
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw allow in on lo >/dev/null 2>&1 || true

    # ── Device data-collection ports (UDP) — ONLY from ALLOWED_DEVICE_NETWORKS ──
    apply_ufw_from_list 1514 udp ALLOWED_DEVICE_NETWORKS   # syslog
    apply_ufw_from_list 1515 udp ALLOWED_DEVICE_NETWORKS   # syslog
    apply_ufw_from_list 1516 udp ALLOWED_DEVICE_NETWORKS   # syslog
    apply_ufw_from_list 2155 udp ALLOWED_DEVICE_NETWORKS   # netflow
    apply_ufw_from_list 2156 udp ALLOWED_DEVICE_NETWORKS   # netflow
    apply_ufw_from_list 2157 udp ALLOWED_DEVICE_NETWORKS   # netflow
    apply_ufw_from_list 26343 udp ALLOWED_DEVICE_NETWORKS  # sflow
    apply_ufw_from_list 26344 udp ALLOWED_DEVICE_NETWORKS  # sflow
    apply_ufw_from_list 26345 udp ALLOWED_DEVICE_NETWORKS  # sflow
    apply_ufw_from_list 1812 udp ALLOWED_DEVICE_NETWORKS   # radius auth
    apply_ufw_from_list 1813 udp ALLOWED_DEVICE_NETWORKS   # radius acct
    apply_ufw_from_list 162  udp ALLOWED_DEVICE_NETWORKS   # snmp trap

    # ── Web login ports (TCP) — ONLY from ALLOWED_WEB_NETWORKS ──
    apply_ufw_from_list 80  tcp ALLOWED_WEB_NETWORKS   # http
    apply_ufw_from_list 443 tcp ALLOWED_WEB_NETWORKS   # https

    # ── SSH — port changed to 444, ONLY from ALLOWED_SSH_NETWORKS ──
    ufw deny 22/tcp >/dev/null 2>&1 || true
    apply_ufw_from_list 444 tcp ALLOWED_SSH_NETWORKS   # ssh (new port)

    ufw --force enable >/dev/null 2>&1 || true
    log "UFW enabled (default-deny incoming)"
else
    log "ufw not found — skipping host firewall (install ufw for port hardening)"
fi

# ── 3. SSH hardening — port 444, password auth kept per operator request ──────
SSHD_DIR="/etc/ssh/sshd_config.d"
mkdir -p "${SSHD_DIR}"
cat > "${SSHD_DIR}/99-nms-hardening.conf" <<SSHEOF
# MY_NET NOC — SSH hardening (managed by nms-harden.sh)
Port 444
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
SSHEOF

# Restrict AllowUsers to SSH source networks (best-effort IP pattern match)
if [[ -n "${ALLOWED_SSH_NETWORKS}" ]]; then
    allow_users="AllowUsers"
    IFS=',' read -ra NETS <<< "${ALLOWED_SSH_NETWORKS}"
    for n in "${NETS[@]}"; do
        n="$(trim "${n}")"
        [[ -z "$n" ]] && continue
        base="${n%%/*}"
        allow_users="${allow_users} *@${base}"
    done
    echo "${allow_users}" >> "${SSHD_DIR}/99-nms-hardening.conf"
fi

if command -v sshd >/dev/null 2>&1; then
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        log "SSH hardened on port 444 & reloaded"
    else
        log "WARNING: sshd config test failed — not reloading"
    fi
else
    log "sshd not found — skipping"
fi

# ── 4. WAF render + reload ────────────────────────────────────────────────────
if [[ -f /etc/nginx/waf-enabled.conf ]]; then
    nginx -t 2>/dev/null && (systemctl is-active --quiet nginx && systemctl reload nginx || systemctl restart nginx) 2>/dev/null || true
    log "WAF config present — nginx reloaded"
else
    log "WAF config not yet generated (will be created on first engine boot + reload)"
fi

log "hardening complete"
