# NMS Engine — Architecture & Operations

The engine is a **single Go binary** (`/usr/local/bin/nms_engine`) running as **8 systemd instances** across two isolated tiers on the host. It is **NOT** a Docker container — Docker runs only the infrastructure (Postgres HA, Redis, NATS, ClickHouse, monitoring).

## Why 8 instances (Split-Role Dual-Tier Architecture)

```
                 ┌─────────────────────────────────────────────────────────────┐
   nginx (host)  │                                                             │
   :443 HTTPS    │   upstream nms_engine { least_conn; 8000-8004 }             │
   :514 syslog   │   stream { 514→1514-1516, 2055→2155-2157, 6343→26343-26345 } │
   :2055 netflow │                                                             │
   :6343 sflow   │                                                             │
                 └───────────────┬─────────────────────────────┬───────────────┘
                                 │ (HTTP API)                  │ (UDP Telemetry)
                                 ▼                             ▼
                 ┌───────────────────────────┐ ┌───────────────────────────────┐
                 │ Tier-B: Web API Cluster   │ │ Tier-A: Polling Worker Cluster│
                 │ nms_engine@8000–@8004     │ │ nms_worker@9000–@9002         │
                 │ (Active-Active, --api)    │ │ (Leader-Elected, --poller)    │
                 └───────────────┬───────────┘ └───────────────┬───────────────┘
                                 │                             │
                                 ▼                             ▼
                 ┌───────────────────────────┐ ┌───────────────────────────────┐
                 │ NMS_LEADER_KEY=           │ │ NMS_LEADER_KEY=               │
                 │ nms:leader:web            │ │ nms:leader:poller             │
                 └───────────────────────────┘ └───────────────────────────────┘
```

- **Tier-B (Web API Cluster: ports `:8000`–`:8004`):**
  - Runs with `--api` flag only.
  - All 5 instances are active; Nginx load balances web traffic (`least_conn`).
  - Zero polling load; sub-millisecond response times for all dashboard queries.
- **Tier-A (Polling Worker Cluster: ports `:9000`–`:9002`):**
  - Runs with `--poller --bgp --syslog --netflow` flags.
  - Dedicated leader election via `nms:leader:poller`.
  - 1 Active Leader performs all router polling while 2 Standbys maintain hot-standby readiness.
- **Deploys are zero-downtime:** `zero-downtime-deploy.sh` rolls Web and Worker clusters one by one; `max_fails=2` makes Nginx skip an instance mid-restart, so clients see zero 502s.

## Ports & configuration

| Port(s) | Owner | Purpose |
|---|---|---|
| 8000-8004 | systemd `nms_engine@<port>` | Tier-B Web API Engines (binds `127.0.0.1` only) |
| 9000-9002 | systemd `nms_worker@<port>` | Tier-A Polling Worker Engines |
| 1514-1516 | worker instances | Syslog collectors (nginx 514 → round-robin) |
| 2155-2157 | worker instances | NetFlow collectors (nginx 2055) |
| 26343-26345 | worker instances | sFlow collectors (nginx 6343) |
| 514 / 2055 / 6343 | nginx stream | External UDP front door |

| File | Owner | Content |
|---|---|---|
| `/etc/nms/nms.env` (0600) | global | DB/Redis/NATS/Telegram secrets, `PORT` etc. |
| `/etc/nms/instances/<port>.env` | per web instance | `NMS_LEADER_KEY=nms:leader:web`, `NMS_LEADER_PRIORITY=999` |
| `/etc/nms/workers/<port>.env` | per poller instance | `SYSLOG_PORT`, `NETFLOW_PORT`, `SFLOW_PORT`, `NMS_LEADER_KEY=nms:leader:poller`, `NMS_LEADER_PRIORITY=$i` |
| `infra/deploy/systemd/nms_engine@.service` | repo (source) | Web API systemd template unit |
| `infra/deploy/systemd/nms_worker@.service` | repo (source) | Polling Worker systemd template unit |
| `infra/deploy/nginx/engine_upstream.conf` | repo (source) | HTTP upstream `nms_engine` (8000-8004) |
| `infra/deploy/nginx/udp-collectors.conf` | repo (source) | UDP stream → per-worker ports (1514-1516, 2155-2157, 26343-26345) |
| `/usr/local/bin/nms_engine` | deployed | current binary |

The unit template sets `EnvironmentFile=/etc/nms/nms.env` and per-instance env files, then exports `PORT=%i`. `Restart=always` + watchdog (`nms_watchdog.service`) cover crashes.
