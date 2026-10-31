# 📝 Changelog

All notable releases and architectural updates to **MY_NET Enterprise NOC** are documented here.

## [1.3.1] - 2026-10-12

### 🔧 Fresh-install fix
- **setup.sh**: creates `/etc/nms` (and `instances/`, `workers/`) before writing `/etc/nms/.setup-pin-hash`. Previously, on a brand-new machine the directory did not exist yet (it was only created at Step 7), so the one-time setup PIN generation failed with `No such file or directory` and aborted the whole install. PIN writes are now atomic (temp file + `mv`) and the script refuses to run unless root. `bundle_lint.sh` gained a guard so this regression cannot ship again.

### 🔒 Follow-up Security Audit — Bulk-Execution Inventory Gate, Verifier SSRF Hardening & Infra Consolidation
- **Bulk-execution inventory gate**: `POST /api/v3/automation/bulk` now validates every target IP against the router inventory **before** any connection is attempted — unknown targets (and any batch containing one) are rejected with 403 plus DENIED audit logging, closing the fallback-credential dial hole that had previously been closed only on the single-terminal path. A shared `requireInventoryFor` gate keeps terminal and bulk behaviour identical.
- **Error-verifier SSRF hardening**: the telemetry error *verify* probe now accepts only internal `/api/` paths (path traversal and external targets are rejected with 400), never follows redirects, and counts HTTP 3xx as *not healthy* instead of treating redirects and authentication pages as success.
- **CORS allowlist completeness**: `X-Trace-ID`, `X-CSRF-Token`, `X-Client-Timezone` and `X-NMS-Background` are now declared in the CORS allowed headers, so browser clients sending those custom headers receive predictable preflight responses.
- **Reverse-proxy consolidation**: all nginx basic-auth realms now share the single `/etc/nginx/.htpasswd` store (three per-service copies retired after verifying the live files were byte-identical); the dormant Grafana HTTPS vhost on `:8081` was removed from the proxy template — dashboards live natively in the System Health page and the Grafana container remains directly reachable on `:3002`.
- **Toolchain & dependencies**: Go `1.26.6 → 1.26.9` and `golang.org/x/net v0.58.0 → v0.60.0`, clearing all nine `govulncheck` findings (GO-2026-6603/6605/6607/6608/6617 — HTTP/2 HPACK encoder race, `crypto/tls` and `mime/multipart` issues) surfaced by the CI vulnerability gate during the release.
- **CI/E2E parity**: the Vite dev/preview proxies no longer rewrite the `Host` header (`changeOrigin: false`), matching production nginx (`proxy_set_header Host $host`) so the CSRF same-site check (Origin vs Host) is exercised identically in CI — previously every mutating Playwright request was rejected with 403, masking the inventory and IPAM E2E specs.
- **E2E CSRF origin fix**: the Playwright API-seeding helper now falls back to the test runner's base URL when the page has not navigated yet — an un-navigated page reports the opaque origin `null`, which the same-site CSRF check intentionally rejects. This cleared the last remaining CI-only E2E failure (IPAM aggregate seeding); production request handling is unchanged.
- **CI `-race`/lint stabilization**: fixed the series of data races flagged by Go's `-race` detector (downalert send-state reads, session-activity test gate, test-lifecycle hooks, and the VictoriaMetrics batcher write-endpoint override) and five `golangci-lint` findings — all synchronization-only changes with production behaviour unchanged, leaving the `-race` and lint CI jobs green.
- **Housekeeping**: `.kilo/` added to `.gitignore`.

---

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
