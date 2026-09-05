# NMS Operations Runbook

Operational playbook for the HA stack. Health checks: `sudo bash /usr/local/bin/verify-ha.sh` (or the watchdog timer, which alerts Telegram on FAIL and re-attaches pgpool nodes automatically).

## Docs
- [ENGINE.md](ENGINE.md) — engine architecture: 5 systemd instances, leader election, ports, config files, deploy/rollback
- [RUNBOOK.md](RUNBOOK.md) — this file: incident playbooks

## Topology

| Layer | Nodes | Access |
|---|---|---|
| Postgres | pg-0 (primary) / pg-1 (standby, streaming, lag ~0) | pgpool :5432 (loopback), direct 15432/25432 (loopback) |
| pgpool | single container, LB reads 50/50, writes to primary, auto-promote via failover.sh | 127.0.0.1:5432 |
| Redis | cache 6380 + replica 6381, Sentinel trio 26379-26381 (quorum 2) | 127.0.0.1 only |
| Engine API | 5 systemd instances nms_engine@8000-8004 (bind 127.0.0.1) | via nginx https |
| ClickHouse | single container (loopback 8123, native 9001, password auth via CLICKHOUSE_PASSWORD) | 127.0.0.1:8123 / 9001 |
| NATS | single container, token auth (NATS_URL in nms.env) | 127.0.0.1:4222 |

Credentials live in `/etc/nms/nms.env` (root 600) and the gitignored stack `.env` files (`infra/deploy/db_cluster/.env`, `infra/deploy/nms_stack/.env`). Never in git.


## Golden rules (learned the hard way)

1. **pgpool_status file**: pgpool persists node states in `/tmp/pgpool_status` (inside its container). Any restart/reboot with a stale "down" entry keeps the node down. Always `docker run --rm --volumes-from pg-pgpool alpine rm -f /tmp/pgpool_status` BEFORE starting pgpool.
2. **Stuck "down" node with no health_check process** → `docker compose up -d --force-recreate pgpool`. `docker restart` does NOT fix it (process state survives).
3. **Bitnami entrypoint**: do NOT rely on `touch standby.signal` — the entrypoint DELETES it on every start (`postgresql_clean_from_restart`, master mode → node starts writable → split-brain). The supported rejoin: persist `PG0_REPL_MODE=slave` + `PG0_MASTER_HOST=pg-1` in `deploy/db_cluster/.env`, wipe the data volume, `docker compose up -d --force-recreate pg-0` — the entrypoint clones from the primary and creates `standby.signal` itself (`postgresql_configure_recovery`). Remove the two lines from `.env` again on failback. Verify `pg_controldata | grep "Time line ID"` matches the primary BEFORE starting.
4. **Replication hba**: the primary needs `host replication ...` in its pg_hba (bitnami master mode generates `replication all`; promoted standbys do NOT — add it manually + `SELECT pg_reload_conf()`). `pg_hba.conf` lives OUTSIDE the data dir (`/opt/bitnami/postgresql/conf/`), so **pg_basebackup does NOT clone it** — every node that may ever become primary needs its own entry (verified: fresh pg-1 clone came up without it). Command: `docker exec -u 0 <node> sh -c "echo 'host replication all 172.18.0.0/16 md5' >> /opt/bitnami/postgresql/conf/pg_hba.conf && chown 1001:1001 /opt/bitnami/postgresql/conf/pg_hba.conf"` + reload.
5. **postgresql.auto.conf is cloned by basebackup and survives promotion**: `pg_ctl promote` does NOT remove a stale `primary_conninfo` from `postgresql.auto.conf`, and every slave boot APPENDS another `primary_conninfo` (last line wins). A stale `host='pg-1'` on the new primary gets copied into the next standby's basebackup → new standby connects to ITSELF (`no pg_hba.conf entry for replication ... from host` on the loopback of its own IP) and never catches up. Fix: after promotion, truncate the new primary's auto.conf to header-only; after each reseed, rewrite the standby's auto.conf with a SINGLE `primary_conninfo` pointing at the real primary (docker cp + `chown 1001:1001` + `pg_ctl reload`).
5. **Controlled maintenance**: stop pgpool first (suppresses failover), do the work, clear pgpool_status, then start pgpool.
6. **Never `docker rm` by hash** during multi-container work — recheck `docker ps` first (one mis-rm'd container cost a scare; recovery = recreate, volumes persist).
9. **freeradius schema**: freeradius needs the full table set (radcheck, radpostauth, radgroupcheck, radgroupreply, radreply, radusergroup, nas, nasreload). `radpostauth` missing silently turns successful logins into Access-Reject (post-auth fail). Recreate from the image: `docker run --rm --entrypoint cat freeradius/freeradius-server:latest /etc/freeradius/mods-config/sql/main/postgresql/schema.sql | psql` (IF NOT EXISTS, safe). `sql.conf` connects via **pg-pgpool** (HA — never a direct node).
 8. **freeradius SQL auth**: the compose interpolates `${PG_PASSWORD}` from `deploy/nms_stack/.env` — a missing/old value (e.g. a stale `P@ssw0rd123!` in the deploy shell) makes rlm_sql fail auth at startup and the container crash-loops (exit 1, no stdout; check `/var/log/freeradius/radius.log`). Keep `PG_USERNAME/PG_PASSWORD/PG_DATABASE` in nms_stack/.env in sync with db_cluster/.env.
 9. **freeradius schema drift**: the live `radacct` table came from an older image schema (extra `groupname` NOT NULL, no IPv6 columns). Accounting packets failing with `42703 UNDEFINED COLUMN` / `23502 NOT NULL VIOLATION` in `/var/log/freeradius/radius.log` (no Accounting-Response) = schema drift. Fix: `ALTER TABLE radacct ADD COLUMN IF NOT EXISTS FramedIPv6Address inet, ADD COLUMN IF NOT EXISTS FramedIPv6Prefix inet, ADD COLUMN IF NOT EXISTS FramedInterfaceId text, ADD COLUMN IF NOT EXISTS DelegatedIPv6Prefix inet, ADD COLUMN IF NOT EXISTS Class text;` then `ALTER TABLE radacct ALTER COLUMN groupname DROP NOT NULL, ALTER COLUMN username DROP NOT NULL, ALTER COLUMN calledstationid DROP NOT NULL, ALTER COLUMN callingstationid DROP NOT NULL, ALTER COLUMN acctterminatecause DROP NOT NULL, ALTER COLUMN framedipaddress DROP NOT NULL;` (running image enforces NOT NULL only on `acctsessionid, acctuniqueid, nasipaddress`). DDL flows pgpool → primary → standby.
7. **Redis topology**: the sentinel-monitored master is `nms-redis-cache` (:6380, AOF, LRU 512MB), replica `nms-redis-replica` (:6381). `nms-redis-queue` (:6379) is a standalone queue bus NOT in the sentinel quorum — stopping it must never be used to "drill" failover.

## Playbooks

### A. Primary down (unplanned)
1. pgpool detects it (10s health check) → failover.sh guard (3x pg_isready, 2s apart) → `pg_ctl promote` on pg-1 automatically.
2. Verify: `SHOW pool_nodes` → pg-1 primary; engines auto-reconnect.
3. Recover old primary as standby (reseed): add `PG0_REPL_MODE=slave` + `PG0_MASTER_HOST=pg-1` to `deploy/db_cluster/.env` → wipe `db_cluster_pg_0_data` volume → `docker compose up -d --force-recreate pg-0` (entrypoint clones + creates standby.signal; replication hba must exist on pg-1 first — promoted standbys lack it; and pg-1's auto.conf must carry NO stale `primary_conninfo`, see golden rule 5). If the cloned standby self-connects, rewrite its `postgresql.auto.conf` with a single `primary_conninfo` → primary + reload. Clear pgpool_status, start pgpool. Remove the `.env` lines when you fail back.

### B. Failback (make pg-0 primary again)
1. `docker stop pg-pgpool` (no failover during the flip)
2. Add replication hba on pg-0 + reload; `pg_ctl promote` pg-0; verify `pg_is_in_recovery() = f`
3. Reseed pg-1 from pg-0: wipe `db_cluster_pg_1_data` volume → `docker compose up -d --force-recreate pg-1` (pg-1 env defaults already `PG1_REPL_MODE=slave` + `PG1_MASTER_HOST=pg-0`)
4. `deploy/db_cluster/.env`: `PG0_REPL_MODE`/`PG0_MASTER_HOST` must be absent (master default) — remove the standby-phase lines if present
5. Clear pgpool_status → `docker compose up -d pgpool` → if a node is stuck `down` (pg_status `up`), attach it: `docker exec pg-pgpool sh -c "echo '127.0.0.1:9898:admin:${PGPOOL_PCP_PASSWORD}' > /tmp/pcppass && chmod 600 /tmp/pcppass && PCPPASSFILE=/tmp/pcppass /opt/pgpool-II/bin/pcp_attach_node -h 127.0.0.1 -U admin -n <id> -p 9898"` → verify-ha

### B'. Failback gotchas (verified 2026-08-08)
- `docker compose up -d pg-1` may RECREATE pg-0 too (env change) — IPs get reassigned; always use compose DNS names, never IPs.
- After `pg_ctl promote` on pg-0: truncate its `postgresql.auto.conf` to the header (stale `primary_conninfo` would otherwise be cloned into the pg-1 reseed → pg-1 self-connects).
- After reseeding pg-1: rewrite its `postgresql.auto.conf` with ONE `primary_conninfo` → `host='pg-0'` (the basebackup clones whatever the primary had). Verify streaming: `pg_stat_replication` on pg-0 + `pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) = 0` on pg-1.

### C. Reboot (planned)
`sudo bash /usr/local/bin/graceful-reboot.sh` (installed by bootstrap; repo copy: `infra/deploy/scripts/graceful-reboot.sh`) — stops pgpool first (no phantom failover), clears pgpool_status; watchdog re-attaches nodes after boot.

**Verified 2026-08-08** (full host reboot): after ~5 min downtime, ALL CHECKS PASSED — 23 containers, engines 8000-8004, no crash loops, sentinel master back on **6380** (default topology restored; pre-reboot drill had left 6381 as master), pool_nodes 0:up/1:up, pg-0→pg-1 streaming, CH auth+tables OK. Observations:
- **Leader term can reset after reboot** (t6 → t2): the new term derives from the lock copy on whichever replica survives (6380 held a stale pre-drill copy). Safe — fencing still holds because no old leader process survives a full reboot; the term only matters when a previous leader might still be alive (split-brain window).
- **Found & fixed by this drill: `nms_engine@8000-8004` were NOT enabled** (`systemctl is-enabled` = disabled) — engines would never have come back after boot. Fix: `for p in 8000 8001 8002 8003 8004; do systemctl enable nms_engine@$p; done`.
- Engine boot ordering is safe: `ExecStartPre=/usr/local/bin/nms_engine_ready.sh` waits for pgpool:5432 + redis:6380 + nats:4222 before starting.

### D. Redis master failure
Sentinel promotes replica within ~10s; engines follow automatically (failover client). Verify: `sentinel get-master-addr-by-name mymaster`, `info replication` on both ports, leader key present. Old master coming back is re-attached as replica by sentinel (static `--replicaof` on 6381 keeps the default topology on full recreation).

### E. Restore from backup
Daily dump: `/var/backups/nms/nms_backup_*.tar.gz` (via pgpool, failover-aware). Offsite copy: with `TELEGRAM_UPLOAD=1` in `/etc/nms/nms.env`, the archive is also sent to the Telegram chat (creds from the PG `settings` table, same source as the relay; >49MB split into chunks; local archive always kept) — verified 2026-08-09 (20MB, 1 chunk, `sendDocument` OK). Restore test: create scratch DB on primary, `pg_restore -Fc`. Drop the scratch DB on the DIRECT node (`docker exec pg-0 psql ... DROP DATABASE`) — DROP through pgpool hangs on pooled connections.

**PG restore drill (verified 2026-08-09, PASSED):** took `nms_backup_20260809_002451.tar.gz`, extracted `rnd_db.dump` (pg_dump -Fc), created scratch `restore_drill` on pg-0 directly, `pg_restore -Fc --no-owner --no-privileges` → 0 errors, 82 tables. Count-compared all 82 tables against prod: 81 exact; the 1 delta (`router_syslogs` 59 vs 56) was pure backup-age skew — 0 live rows in the (restore_max, backup_time) window and 0 restore rows after backup time, so the snapshot was complete and consistent. Dropped the scratch DB on pg-0 direct (not pgpool). NOTE: `docker cp` writes the dump as root into the container — remove it with `docker exec -u 0 pg-0 rm -f /tmp/...`.

**CH restore re-verify with dedup schema (2026-08-09, PASSED):** restored all 4 raw tables from `ch_20260809_035547` into scratch DB `restore_test` via `RESTORE TABLE default.<tbl> AS restore_test.<tbl> FROM File(...)` (docker cp the backup dir into `/var/lib/clickhouse/backups/`, `chown -R clickhouse:clickhouse` first — docker cp changes ownership). All `RESTORED`; plain counts + `FINAL` counts matched live on all tables (0/0/1/24), i.e. ReplacingMergeTree dedup semantics survive a restore.

**ClickHouse:** backup = `BACKUP DATABASE default TO File(...)` (inside `clickhouse_backup/ch_*`). Restore: `docker cp` back into the container, then `chown -R clickhouse:clickhouse` the dir (docker cp changes ownership → RESTORE fails with Permission denied otherwise), then `RESTORE TABLE default.<tbl> AS <scratch>.<tbl> FROM File('/var/lib/clickhouse/backups/ch_<ts>')` (AS syntax; `INTO` is not supported in 24.3); verify counts vs prod; DROP the scratch DB.

**Corrupt-part gotcha (caught by 2026-08-08 drill):** a part written during the TTL-mutation window produced `count.txt=1` but a truncated `data.bin` (clickhouse-local read: "Bytes read: 391. Bytes expected: 44M"). It restored "RESTORED" but read 0 rows — silently useless backups. Detection: `find <backup>/data/default/<tbl> -name count.txt -exec cat {} +` vs live `count()` (now automated in backup.sh, logs "ClickHouse backup integrity OK/WARN"). Fix: drop the corrupt part (`ALTER TABLE ... DROP PART '<name>'` — safe when queries read 0 rows from it) and re-run the backup; verified clean restore after doing so.

## Credential rotation map (when passwords change)
- `/etc/nms/nms.env`: DATABASE_URL, PG_PASSWORD, PG_REPL_PASSWORD, REDIS_PASSWORD, NATS_TOKEN/NATS_URL, Telegram, SENTRY_DSN (frontend + backend)
- `deploy/db_cluster/.env`: PG_PASSWORD, PG_REPL_PASSWORD, PGPOOL_PCP_PASSWORD (pgpool must be recreated to pick up)
- `deploy/nms_stack/.env`: REDIS_PASSWORD, NATS_TOKEN
- Sentinel confs (s1/s2/s3, gitignored): `sudo deploy/scripts/apply_redis_auth.sh` rewrites from nms.env
- Git history: `git filter-repo --replace-text <redact>` + force push

## RADIUS NAS Secret Configuration

The FreeRADIUS NAS secret is stored in `secrets/RADIUS_NAS_SECRET`. Replace the placeholder with your actual secret value before deployment:

```bash
# Generate a secure secret
openssl rand -hex 32
# Edit the secret file
sudo vi secrets/RADIUS_NAS_SECRET
# The template renders: secret = __RADIUS_SECRET__ from the env var
```

## Backup & Restore Automation

### Daily Backup Schedule
- **Time:** 02:00 UTC daily
- **Script:** `scripts/backup.sh`
- **Encryption:** `openssl enc -aes-256-cbc -pbkdf2 -pass env:BACKUP_ENC_KEY`
- **Output:** `nms_backup_YYYYMMDD_HHMMSS.tar.gz`
- **Permissions:** 600 (owner-only read/write)

### Monthly Restore Drill
- **Script:** `scripts/pg-restore.sh --verify`
- **Validation:** Compare checksums of restored data vs current DB snapshot
- **Expected:** All 82 tables match within backup-age tolerance

### Offsite Sync
- **Target:** Configured per deployment (set `OFFSITE_BACKUP_HOST` in `/etc/nms/nms.env`)
- **Encryption:** SCP with AES-256
- **Retention:** 7 daily + 12 monthly backups

## Chaos Drill Documentation

### Drill 1: PG Primary Failure
```bash
# Stop pg-0 container
docker stop nms-pg-0
# Expected: failover.sh promotes pg-1 within ~9s
# Verify: SHOW pool_nodes → pg-1 primary
```

### Drill 2: ClickHouse Outage
```bash
# Stop clickhouse
docker stop nms-clickhouse
# Expected: records spill to /var/lib/nms/buffer_spill/
# Restart clickhouse → auto-drain on next tick
```

### Drill 3: NATS Outage
```bash
# Stop NATS
docker stop nms-nats
# Expected: memory fallback (50k/topic cap) + reconnect loop
# Restart NATS → 5/5 messages recovered
```

### Drill 4: Leader Engine Kill
```bash
# Kill the leader engine
sudo systemctl stop nms_engine@8000.service
# Expected: peer steals lock within ~15s
# Verify: redis-cli GET nms:leader:worker
```

## Telemetry pipeline (NATS → ClickHouse)
Collectors publish to NATS topics (`netflow_raw`, `sflow_raw`, `radius_acct_raw`, `syslog_raw`); one engine instance consumes via queue group and batches 2s → ClickHouse (tables in `default` DB: 4 raw tables). Failure ladder: CH down → 3× backoff retry → **disk spill** `/var/lib/nms/buffer_spill/*.spill` → auto-drain on recovery (drain runs every tick even with no fresh data). NATS down → bounded in-memory fallback (50k/topic) + reconnect loop + Telegram alerts. Observability: `nms_buffer_*` metrics on `/metrics` (spilled/dropped counters, backlog gauge). Credentials: `CLICKHOUSE_PASSWORD` in nms.env; CH user config source = `deploy/nms_stack/clickhouse-users.d/` (directory-mounted to hide the image's `default-user.xml`).

**syslog → ClickHouse (fixed 2026-08-08):** syslog never reached CH before — `flushSyslogDedup` wrote PG `router_syslogs` + Redis `syslog_events` only, and nothing published to the `syslog_raw` NATS topic (so `syslog_raw` stayed at 0 rows despite the 90-day TTL). Now each flushed entry is also pushed through the buffer (NATS → journal → CH).

**CH-outage drill (verified 2026-08-08):** `docker stop nms-clickhouse` → inserts fail → records spill to `/var/lib/nms/buffer_spill/<topic>.<instance>.spill` within the next 1s flush tick (per-instance files, no cross-instance read/truncate race; 5/5 drill messages journaled) → `docker start nms-clickhouse` → journal drains itself on the next tick (0 files left, all rows present). Delivery is **at-least-once** (insert may commit while the HTTP response is lost / engine dies before journal removal → identical rows re-inserted). Duplicates are now removed by the schema itself: every `default.*_raw` table carries `id UInt64 DEFAULT cityHash64(<entire payload>)` with `ENGINE = ReplacingMergeTree() ORDER BY (timestamp, id)` — byte-identical replays collide on the same key and collapse on merge (server-side DEFAULT, engine unchanged). Verify with `SELECT ... FINAL` (or `OPTIMIZE TABLE ... FINAL` to materialize). **Dedup drill (verified 2026-08-08):** 5 syslog messages via UDP :514 → engine → NATS → CH (5/5 in `syslog_raw`), then re-inserted the same 5 rows byte-identically (simulated journal replay): plain count 10 → `FINAL` 5 → after `OPTIMIZE ... FINAL` plain count 5. Migration path for live tables: create `<tbl>_new` (new schema) → `INSERT SELECT *, cityHash64(...) FROM <tbl>` → `RENAME TABLE <tbl> TO <tbl>_old, <tbl>_new TO <tbl>` → drop `<tbl>_old` (POST via HTTP interface, GET is read-only).

**NATS-outage drill (verified 2026-08-08):** 5 messages sent during `docker stop nms-nats` sat in the memory fallback (50k/topic cap) and drained to CH after restart — 5/5 recovered, zero loss.

## Metrics pipeline
Engine `/metrics` binds loopback only; `nms_metrics_bridge.service` (systemd, socat) forwards docker0:8000 → 127.0.0.1:8000 so VictoriaMetrics can scrape. If the engine `up` drops to 0 in Grafana: check the bridge unit (`systemctl status nms_metrics_bridge`).

## Alert delivery (Grafana → Telegram)
- Grafana provisioned alerts → contact point `webhook-main` → `http://host.docker.internal:8098/` (grafana service has `extra_hosts: host.docker.internal:host-gateway`).
- Relay: `nms-telegram-relay.service` (systemd, `/usr/local/bin/telegram-relay.py`, stdlib http.server on 0.0.0.0:8098), forwards to the same bot/chat the engine uses (reads `telegram_token`/`telegram_chat_id` from PG `settings` table; `DATABASE_URL` comes from `EnvironmentFile=/etc/nms/nms.env`). Journal: `journalctl -u nms-telegram-relay` (note: `python3 -u` is required — buffered stdout otherwise hides request lines).
- ufw rule `8098/tcp allow from 172.16.0.0/12` — without it, container → host POSTs time out (slirp NAT lands on host loopback, INPUT policy DROP).
- Provisioned alert rules need per-rule `notification_settings: receiver: webhook-main` in `rules.yml`; otherwise instances lack the `__grafana_receiver__` label, silently fall through the autogenerated route and never notify. Rule/alerting YAML changes require `docker compose up -d --force-recreate grafana` (the provisioning API reload only re-applies the startup cache; files are read at boot).
- RADIUS dashboard alerts (`radius_no_active_sessions`, `netflow_traffic_drop`) are API-provisioned rules — `notification_settings: receiver: webhook-main` was added via `PUT /api/v1/provisioning/alert-rules/{uid}` (full rule JSON in body; `["uid"]` → 400). Grafana provisions YAML only affect file-provisioned rules; API rules survive force-recreates.
- Non-Grafana alerters: `nms_watchdog.service` (1-min timer: auto-heal engines/nginx/pgpool + pgpool node re-attach + HA sweep, TG on FAIL→OK transitions, creds via DB `settings` fallback) and `nms-ha-daily.timer` (07:30 daily: verify-ha + backup freshness >36h → TG via relay). Both are safe to re-run manually (`systemctl start`).
- NATS-outage drill (verified 2026-08-08): `docker stop nms-nats` → engines' `DisconnectErrHandler` fires `throttledAlert` (🔴 NATS disconnected, no log line — TG only; verify via user's chat or `getUpdates`) → `docker start nms-nats` → `ReconnectHandler` (🟢 reconnected). Zero drops/spills in this window (backlog 0, dropped 0). Engine alert sends are silent-on-success (only errors logged).

## Leader election & failover (engine worker scope)

Worker-scoped components (scheduler, poller, BGP, RADIUS poller) run on exactly ONE instance via the Redis leader lock `nms:leader:poller` (JSON `{h,p,t}`: holder, priority, fencing term).

- **Priority:** `NMS_LEADER_PRIORITY` per instance in `/etc/nms/workers/<port>.env` for Polling workers (9000=0, 9001=1, 9002=2). The highest-priority LIVE poller instance always leads. Web instances have priority 999 and run in `--api` mode under `nms:leader:web`.
- **Auto-return (graceful handoff):** when the preferred leader (9000) returns, it writes a preempt record (`nms:leader:poller:preempt`); the current holder transfers the lock to it via an atomic Lua script on its next renew — term increments, **no gap, no acquire race**.
- **Failover:** leader killed/crashed → its heartbeat TTL goes stale → a peer (highest priority first) steals the lock within ~15s, no manual intervention.
- **Drill procedure:** `sudo systemctl stop nms_worker@9000.service` → watch `redis-cli -p 6380 GET nms:leader:poller` → `sudo systemctl start nms_worker@9000.service` → expect handoff to 9000 within ~3s.
- **Watch:** leader/term via `redis-cli -p 6380 GET nms:leader:poller`; per-instance leader state in `journalctl -u nms_worker@900X`.

## Deploy on a NEW server (portability)

1. Check out the repo at any path; `sudo bash infra/deploy/scripts/bootstrap.sh` — installs systemd units (8-instance split-role templates: 5 web + 3 pollers), per-instance env files with priorities, nginx configs with the repo path baked in (sed), helper scripts to `/usr/local/bin`, and records `NMS_REPO=<path>` in `/etc/nms/nms.env`.
2. `sudo bash infra/deploy/scripts/zero-downtime-deploy.sh /usr/local/bin/nms_engine` (or let CI deploy).
3. `sudo bash /usr/local/bin/verify-ha.sh` — all checks green.
4. The stack containers (PG/pgpool, Redis+Sentinel, CH, NATS, freeradius, grafana, …) come up via `infra/deploy/db_cluster/` + `infra/deploy/nms_stack/` compose files; NATS/CH credentials must match nms.env.

## CI/CD pipeline (main push → auto-deploy)

`.github/workflows/go-ci.yml` (`CI / CD Pipeline`) is the single source of truth — every push to `main` touching `go_engine/`, `frontend/`, `deploy/`, `Dockerfile` or workflows runs it (verified green 2026-08-09):

1. **go-backend-ci** — golangci-lint v2.12.2 (working-directory `go_engine`), `go vet`, test suite (needs redis service), coverage floor 3%, then builds the engine: `go build -ldflags="-s -w" -o nms_engine ./cmd/nms_engine` (root `go build .` is **not** valid since the refactor — package lives in `cmd/nms_engine`; same rule applies to the root `Dockerfile` and any `go build` invocation).
2. **frontend-ci** — npm ci, lint, test, `npm run build` → `frontend/dist` artifact.
3. **e2e-ci** — self-contained stack: PG (seed `deploy/ci/init_ci.sql` + `seed_demo_data.sql`, password from secret `NMS_TEST_PASSWORD`), redis, engine on :8000, Playwright against `PW_BASE_URL=http://127.0.0.1:4173`.
4. **docker-build-ci** — `docker build` with the root `Dockerfile` (buildx, gha cache, no push).
5. **deploy-ci** (self-hosted `nms-server`, `environment: production`, main only) — downloads both artifacts, runs `zero-downtime-deploy.sh`, then copies the frontend dist to the nginx docroot. The target root resolves **dynamically** (no hardcoded path): `NMS_REPO` env → `NMS_REPO` recorded in `/etc/nms/nms.env` by bootstrap → runner workspace. The runner workspace fallback means the frontend copy is skipped (dist already there); on servers with `NMS_REPO` set, the copy targets that checkout (e.g. the nginx docroot). Health-check: `https://127.0.0.1/api/v3/health`.

Deploy rollback: the script keeps the previous binary (see its own echo output for paths); engine was auto-redeployed by CI on 2026-08-09 (`c46a297`, 5/5 healthy, zero downtime).

## RADIUS rule pause (maintenance window)

Happy-hour (night boost) and FUP enforcement can be paused without touching freeradius: set `nb_enabled` / `fup_enabled` to `false` in `system_settings` (UI: Automation Center page, or `UPDATE system_settings SET value='false' WHERE key='nb_enabled'`). The scheduler tasks check the flag on every run (`happy_hour_start` 22:00, `happy_hour_stop` 06:00, `fup_daemon` every 15 min) and skip when not `"true"` — takes effect at the next scheduled run, no restart. Re-enable with `true` after the window. Baseline on this server: both `false` (verified 2026-08-08).
