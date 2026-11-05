#!/bin/bash
# ==============================================================================
# FastNetMon ban callback → MY_NET NOC integration
#
# Fired by FastNetMon when an attack is detected (ban). Does two things:
#   1. Telegram alert with the attack details (same channel as the watchdog)
#   2. Triggers the NMS engine's automatic-mitigation endpoint, which pushes
#      the SAME blackhole flow the Security Center uses (30 min, audited)
#
# Credentials come from the read-only mount of /etc/nms/nms.env.
# FastNetMon passes attack details as environment variables.
# ==============================================================================
set -uo pipefail

[ -f /etc/nms/nms.env ] && { set -a; . /etc/nms/nms.env; set +a; }

# ── FastNetMon-provided context (defensive fallbacks) ──
VICTIM="${VICTIM:-${victim:-unknown}}"
DIRECTION="${FASTNETMON_ATTACK_DIRECTION:-${attack_direction:-unknown}}"
PROTOCOL="${FASTNETMON_ATTACK_PROTOCOL:-${attack_protocol:-unknown}}"
PPS="${total_traffic_pps:-0}"
MBPS="${total_traffic_mbps:-0}"
ACTION="${ACTION:-ban}"

# ── 1. Telegram alert ──
if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT:-}" ]; then
    TEXT="🚨 <b>FastNetMon: ${ACTION^^} detected</b>
Target: <code>${VICTIM}</code>
Direction: ${DIRECTION} · Protocol: ${PROTOCOL}
Traffic: ${MBPS} Mbps / ${PPS} pps
Auto-mitigation: requesting NMS blackhole (30 min)"
    curl -s -m 10 "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT}" -d "text=${TEXT}" -d "parse_mode=HTML" >/dev/null 2>&1 || true
fi

# ── 2. NMS automatic-mitigation trigger (loopback, shared-secret auth) ──
if [ -z "${FASTNETMON_SECRET:-}" ]; then
    echo "FASTNETMON_SECRET not set — skipping NMS trigger" >&2
    exit 0
fi
if [ "${ACTION}" != "ban" ]; then
    echo "non-ban event (${ACTION}) — no mitigation trigger" >&2
    exit 0
fi
PAYLOAD=$(printf '{"attack_ip":"%s","traffic_pps":%s,"traffic_mbps":%s,"direction":"%s","attack_type":"FastNetMon threshold breach"}' \
    "${VICTIM}" "${PPS}" "${MBPS}" "${DIRECTION}")
curl -s -m 15 -X POST "http://127.0.0.1:8000/api/v3/security/ddos/fastnetmon" \
    -H "X-Webhook-Token: ${FASTNETMON_SECRET}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" >/dev/null 2>&1 || true
echo "NMS mitigation trigger sent for ${VICTIM}"
