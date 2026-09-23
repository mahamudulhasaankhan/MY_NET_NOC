# 📝 Changelog

All notable releases and architectural updates to **MY_NET Enterprise NOC** are documented here.

## [1.2.0] - 2026-09-09

### 📉 Integrated Monitoring — Native System Health Dashboard (ClickHouse-Backed Flow/Syslog Viewer)
- **System Health page** (`/monitoring/system-health`): live host (CPU/Mem/Disk/Load/Net), NMS Engine (HTTP rate, p99, goroutines, auth failures), PostgreSQL HA and Redis HA metrics — rendered natively in the UI with 30s auto-refresh and inline SVG sparklines.
- **NetFlow Traffic card**: top talkers by bytes, protocol distribution and flows/min trend, queried live from ClickHouse (`netflow_raw`) — restores the Grafana NetFlow Traffic dashboard in the NMS UI.
- **Syslog viewer**: latest ClickHouse `syslog_raw` messages with severity-coloured badges and facility tags.
- ClickHouse remains the telemetry store for all raw pipelines (`netflow_raw`, `syslog_raw`, `sflow_raw`, `radius_acct_raw`); no additional infrastructure is required for the new viewer.

---

## [1.1.0] - 2026-08-29

### ⚡ Architectural Upgrade — Enterprise Split-Role Dual-Tier Cluster & Decoupled Migrations
- **Decoupled Pre-Flight Migrations (`--migrate`)**: Migrations decoupled from server boot loop; schema verified in pre-flight phase, reducing engine startup time from 4 minutes to **under 20 milliseconds**.
- **Shared DB Connection Pooling**: Connection pool optimization eliminating cold-start stampedes across 8 instances.
- **Split-Role 8-Instance Architecture**: Decoupled Web API traffic (5 Active-Active instances on ports `8000`-`8004`) from Background Polling (3 Leader-Elected workers on ports `9000`-`9002`).
- **Dynamic Branded HA Alerts**: Automatic fallback resolution for `NMS_INSTANCE_NAME=MY_NET_NOC` in Telegram HA leadership notifications.
- **1-Command Turnkey Installer**: Added one-line curl installer for rapid bare-metal and cloud VPS deployment.
- **Lead Architect**: Designed & Engineered by [Md. Mahamudul Hassan Khan](https://www.linkedin.com/in/md-mahamudul-hassan-khan/).

---

## [1.0.0] - 2026-08-23

### 🚀 Major Release — Enterprise GA
- **Go Engine HA Core**: 5-instance active-standby cluster with sub-second failover.
- **Carrier Telemetry**: 100k flows/sec NetFlow v5/v9 and sFlow real-time parser.
- **BGP Telemetry Engine**: Continuous RFC 4271 peer monitoring with Telegram relay alerts.
- **DDoS Mitigation Suite**: MikroTik BGP `/32` blackhole engine with one-click trigger & release.
- **Turnkey 1-Click Installer**: Automated `setup.sh` installer with dependency resolution and TLS generation.
