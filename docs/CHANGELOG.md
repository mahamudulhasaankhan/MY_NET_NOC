# 📝 Changelog

All notable releases and architectural updates to **MY_NET Enterprise NOC** are documented here.

## [1.3.0] - 2026-10-12

### 📦 Public Distribution Completeness, Telemetry Schema & Security Hardening
- **Complete public bundle**: `infra/deploy/db_cluster/` (PostgreSQL HA cluster compose + failover tooling) now ships in the public distribution — previously excluded, which blocked fresh installs at installer Step 9. Rendered secrets and `.env` files remain excluded and are regenerated at install time.
- **Publish completeness gate**: new `bundle_lint.sh` publish gate verifies every path the installer requires, embedded DB migrations in the engine binary, shell syntax of all shipped scripts, secret hygiene, and `docker compose config` validity for both stacks before any release can be pushed.
- **Installer hardening**: Step 9 fails with an actionable message (instead of a silent `set -e` abort) if the bundle is incomplete; `db_cluster_default` network is auto-created; `verify-install.sh` is installed to `/usr/local/bin`.
- **Telemetry schema fixes**: metrics writer for `InsertMetrics`, batch traffic-history writers, 30-day retention sweep, and error-logging fixes for the flow/latency pipelines.
- **Security hardening**: router terminal inventory gate + SSH host-key TOFU pinning, conservative same-site CSRF enforcement, restart-command allowlist, AES key derivation upgraded to SHA-256 KDF (legacy decrypt fallback retained), firewall IP validation, and least-privilege FastNetMon ban-callback environment.
- **Release engineering**: single-source versioning from the `VERSION` file (installer stamp, README badge and release commits now cannot drift).

---

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
