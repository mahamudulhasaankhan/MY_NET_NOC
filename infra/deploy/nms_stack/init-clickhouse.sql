CREATE DATABASE IF NOT EXISTS analytics;

CREATE TABLE IF NOT EXISTS analytics.radacct_logs (
    radacctid UInt32,
    acctsessionid String,
    acctuniqueid String,
    username String,
    groupname String,
    realm Nullable(String),
    nasipaddress String,
    nasportid Nullable(String),
    nasporttype Nullable(String),
    acctstarttime Nullable(DateTime),
    acctupdatetime Nullable(DateTime),
    acctstoptime Nullable(DateTime),
    acctinterval Nullable(Int32),
    acctsessiontime Nullable(Int32),
    acctauthentic Nullable(String),
    connectinfo_start Nullable(String),
    connectinfo_stop Nullable(String),
    acctinputoctets Nullable(Int64),
    acctoutputoctets Nullable(Int64),
    calledstationid String,
    callingstationid String,
    acctterminatecause String,
    servicetype Nullable(String),
    framedprotocol Nullable(String),
    framedipaddress String
) ENGINE = MergeTree()
ORDER BY (acctstarttime, username)
PARTITION BY toYYYYMM(acctstarttime)
TTL acctstarttime + INTERVAL 12 MONTH DELETE
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS analytics.netflow_logs (
    timestamp DateTime,
    src_ip String,
    dst_ip String,
    src_port UInt16,
    dst_port UInt16,
    protocol UInt8,
    bytes UInt64,
    packets UInt64
) ENGINE = MergeTree()
ORDER BY (timestamp, src_ip)
PARTITION BY toYYYYMM(timestamp)
TTL timestamp + INTERVAL 6 MONTH DELETE;

-- Grafana monitoring user is provisioned by apply_secrets.sh -> grafana-user.sql
-- (password is env-driven, never committed).

-- Raw ingestion tables for the NATS buffer pipeline (engine topics).
-- Unknown JSON fields are skipped and nested objects stored as strings via
-- query-level settings (input_format_skip_unknown_fields etc.), so schema
-- drift never breaks ingestion again.
--
-- Duplicate protection (at-least-once buffer -> CH): each row carries a
-- deterministic id = cityHash64(entire payload). The engine's journal replay /
-- ambiguous-failure retries re-send byte-identical rows, which then collide on
-- the same (timestamp, id) ORDER BY key and are collapsed by ReplacingMergeTree
-- on merge. `id` is a server-side DEFAULT, so the engine needs no changes;
-- dedup kicks in on background merges (verify with SELECT ... FINAL or OPTIMIZE).
CREATE TABLE IF NOT EXISTS default.netflow_raw (
    timestamp UInt64, src_ip String, dst_ip String, bytes UInt64, protocol String,
    id UInt64 DEFAULT cityHash64(toString(timestamp), src_ip, dst_ip, toString(bytes), protocol)
) ENGINE = ReplacingMergeTree() ORDER BY (timestamp, id)
TTL toDateTime(timestamp) + INTERVAL 90 DAY DELETE SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS default.sflow_raw (
    timestamp UInt64, agent String, seq_num UInt32, sample String,
    id UInt64 DEFAULT cityHash64(toString(timestamp), agent, toString(seq_num), sample)
) ENGINE = ReplacingMergeTree() ORDER BY (timestamp, id)
TTL toDateTime(timestamp) + INTERVAL 90 DAY DELETE SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS default.radius_acct_raw (
    timestamp UInt64, radacctid UInt64, username String, acctsessionid String,
    acctsessiontime UInt64, acctinputoctets UInt64, acctoutputoctets UInt64,
    framedipaddress String, acctstarttime Nullable(DateTime),
    acctstoptime Nullable(DateTime), acctterminatecause String,
    nasipaddress String, acctauthentic String
) ENGINE = ReplacingMergeTree() ORDER BY radacctid
TTL toDateTime(timestamp) + INTERVAL 90 DAY DELETE SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS default.syslog_raw (
    timestamp UInt64, message String, host String, facility String, severity String,
    id UInt64 DEFAULT cityHash64(toString(timestamp), message, host, facility, severity)
) ENGINE = ReplacingMergeTree() ORDER BY (timestamp, id)
TTL toDateTime(timestamp) + INTERVAL 90 DAY DELETE SETTINGS ttl_only_drop_parts = 1;


-- Client & system error telemetry (frontend errors, unhandled rejections,
-- system trace anomalies). Previously this DDL lived in the Postgres
-- migrations folder where golang-migrate silently skipped it — fresh
-- deployments never got the table and error telemetry degraded to an
-- in-memory ring.
CREATE DATABASE IF NOT EXISTS nms;

CREATE TABLE IF NOT EXISTS nms.client_error_logs
(
    date          Date DEFAULT today(),
    ts            DateTime DEFAULT now(),
    trace_id      String,
    user_id       String,
    route         String,
    error_type    LowCardinality(String),
    message       String,
    stack_trace   String,
    user_agent    String,
    screen        String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, error_type, ts)
TTL date + INTERVAL 90 DAY;
