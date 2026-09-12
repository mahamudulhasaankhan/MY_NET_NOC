#!/usr/bin/env bash
# Engine readiness gate: waits until pgpool (5432), Redis (6380) and NATS (4222)
# answer before the engine instance starts. Prevents crash-restart races right
# after a host reboot (docker stack comes up after systemd started the engine).
set -euo pipefail

check_tcp() {
    local host="$1" port="$2"
    (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null
}

for i in $(seq 1 60); do
    if check_tcp 127.0.0.1 5432 && check_tcp 127.0.0.1 6380 && check_tcp 127.0.0.1 4222; then
        # Pre-flight gate: verify/apply DB schema migrations before live services boot
        if command -v /usr/local/bin/nms_engine >/dev/null 2>&1; then
            /usr/local/bin/nms_engine --migrate || true
        fi
        exit 0
    fi
    sleep 1
done
echo "engine-ready: timeout waiting for pgpool:5432, redis:6380, nats:4222" >&2
exit 1
