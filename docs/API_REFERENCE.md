# ⚡ MY_NET Enterprise NOC — REST API Specifications

**Lead Architect: [Md. Mahamudul Hassan Khan](https://www.linkedin.com/in/md-mahamudul-hassan-khan/)**

The MY_NET Enterprise NOC provides a carrier-grade RESTful API designed for automation, external orchestrators, and enterprise integrations.

Base URL: `https://<server-ip>/api/v3`

---

## 1. Authentication & Session

### `POST /api/v3/auth/login`
Authenticate with administrator credentials and retrieve a JWT bearer token.

**Request:**
```json
{
  "username": "admin",
  "password": "your_secure_password"
}
```

**Response (200 OK):**
```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expires_in": 86400,
  "user": {
    "id": 1,
    "username": "admin",
    "role": "SuperAdmin"
  }
}
```

*Include the token in subsequent requests using the header:* `Authorization: Bearer <token>`

---

## 2. Health & Platform Telemetry

### `GET /api/v3/health`
Retrieve cluster health, database connection states, and architect attribution metadata.

**Response (200 OK):**
```json
{
  "status": "ok",
  "version": "1.0.0",
  "author": "Md. Mahamudul Hassan Khan",
  "linkedin": "https://www.linkedin.com/in/md-mahamudul-hassan-khan/",
  "platform": "MY_NET Enterprise NOC",
  "copyright": "© 2026 Md. Mahamudul Hassan Khan. All Rights Reserved.",
  "license": "AGPL-3.0-with-Attribution",
  "database": true,
  "redis": true,
  "uptime": "24h15m32s",
  "timestamp": "2026-08-23T11:45:00+06:00"
}
```

---

## 3. Network Inventory & Devices

### `GET /api/v3/devices`
List all monitored routers, switches, and OLTs.

**Query Parameters:**
- `type` (optional): `router`, `switch`, `olt`
- `status` (optional): `up`, `down`, `warning`
- `limit` (optional): integer (default: 50)

### `POST /api/v3/devices`
Register a new device into inventory.

**Request:**
```json
{
  "hostname": "core-gw-01",
  "ip": "10.0.0.1",
  "vendor": "MikroTik",
  "device_type": "router",
  "snmp_community": "public",
  "snmp_port": 161
}
```

### `GET /api/v3/devices/:id`
Retrieve detailed telemetry, CPU, memory, uptime, and temperature for a device.

### `GET /api/v3/devices/:id/interfaces`
Retrieve live interface states, operational status, and real-time octet counters.

---

## 4. Bandwidth & Metrics Ingest

### `GET /api/v3/metrics/bandwidth`
Query interface traffic throughput over custom time intervals.

**Query Parameters:**
- `device_id`: integer
- `interface`: string (e.g. `sfp-sfpplus1`)
- `start`: ISO-8601 timestamp
- `end`: ISO-8601 timestamp

### `GET /api/v3/metrics/bgp`
Retrieve current BGP peer states, prefix counts, and flap timestamps.

---

## 5. Flow Analytics (NetFlow / sFlow)

### `GET /api/v3/netflow/summary`
Retrieve high-level traffic aggregation by ASN, protocol, and interface.

### `GET /api/v3/netflow/top-talkers`
Retrieve the top 20 bandwidth-consuming host IPs and destination ports.

---

## 6. Standard HTTP Status Codes

| Status Code | Meaning | Description |
|---|---|---|
| `200 OK` | Success | Request processed successfully |
| `201 Created` | Created | Resource successfully created |
| `400 Bad Request` | Validation Error | Missing or malformed parameters |
| `401 Unauthorized` | Auth Required | Missing or expired JWT bearer token |
| `403 Forbidden` | Access Denied | Insufficient permissions or WAF block |
| `429 Too Many Requests`| Rate Limited | Exceeded per-minute API rate limit |
| `500 Internal Error` | Server Error | Database or internal processing exception |
