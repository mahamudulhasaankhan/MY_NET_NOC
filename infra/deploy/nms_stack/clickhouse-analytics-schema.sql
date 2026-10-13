-- MY_NET NOC — ClickHouse analytics schema bootstrap
-- Applied automatically by setup.sh right after the Docker stack boots.
-- Idempotent (IF NOT EXISTS) — safe to re-run on every install/upgrade.
--
-- Schemas mirror the engine's JSONEachRow column contracts:
--   cmd/nms_engine/netflow.go / netflow_v9.go  → netflow_raw (UnixNano ts)
--   cmd/nms_engine/syslog.go                   → syslog_raw  (epoch-sec ts)
--   cmd/nms_engine/sflow.go                    → sflow_raw   (UnixNano ts)
--   cmd/nms_engine/radacct.go                  → radius_acct_raw (epoch-sec ts)
-- These tables MUST live in the `default` database: the engine pipeline and
-- verify-ha both resolve them there.
-- 90-day TTLs bound disk growth; raise if longer flow history is needed.

CREATE TABLE IF NOT EXISTS default.netflow_raw (
  timestamp UInt64,
  src_ip String,
  dst_ip String,
  src_port UInt16,
  dst_port UInt16,
  bytes UInt64,
  packets UInt64,
  protocol String,
  exporter_ip String
) ENGINE = MergeTree ORDER BY (timestamp, src_ip) TTL toDateTime(timestamp/1000000000) + INTERVAL 90 DAY;

CREATE TABLE IF NOT EXISTS default.syslog_raw (
  timestamp UInt32,
  message String,
  host String,
  facility String,
  severity String
) ENGINE = MergeTree ORDER BY (timestamp, host) TTL toDateTime(timestamp) + INTERVAL 90 DAY;

CREATE TABLE IF NOT EXISTS default.sflow_raw (
  timestamp UInt64,
  agent String,
  seq_num UInt32,
  sample String
) ENGINE = MergeTree ORDER BY (timestamp, agent) TTL toDateTime(timestamp/1000000000) + INTERVAL 90 DAY;

CREATE TABLE IF NOT EXISTS default.radius_acct_raw (
  radacctid UInt64,
  username String,
  acctsessionid String,
  acctsessiontime Int64,
  acctinputoctets Int64,
  acctoutputoctets Int64,
  framedipaddress String,
  acctstarttime String,
  acctstoptime String,
  acctterminatecause String,
  nasipaddress String,
  acctauthentic String,
  timestamp UInt32
) ENGINE = MergeTree ORDER BY (timestamp, username) TTL toDateTime(timestamp) + INTERVAL 90 DAY;
