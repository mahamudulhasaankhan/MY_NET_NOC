# 📖 MY_NET Enterprise NOC — Operator & User Manual

**Lead Architect: [Md. Mahamudul Hassan Khan](https://www.linkedin.com/in/md-mahamudul-hassan-khan/)**

---

## 1. Initial Access & Security Hardening

### 1.1 Logging In
1. Navigate to: `https://<your-server-ip>`
2. Accept the self-signed TLS certificate in your browser.
3. Login using your administrator credentials configured during installation.

### 1.2 Two-Factor Authentication (2FA/TOTP)
1. Go to **Settings > Security & Profile**.
2. Click **Enable 2FA**.
3. Scan the generated QR Code with Google Authenticator or Microsoft Authenticator.
4. Input the 6-digit verification code to lock your account.

---

## 2. Onboarding Network Devices

### 2.1 Supported Hardware & OS
- **MikroTik RouterOS** (v6.x / v7.x via API & SSH)
- **Cisco Systems** (IOS, IOS-XE, IOS-XR via SNMP & SSH)
- **Juniper Networks** (JunOS via SNMP & NETCONF)
- **Linux / BSD Servers** (SNMP & Node Exporter)
- **GPON / EPON OLTs** (ZTE, Huawei, BDCOM via SNMP)

### 2.2 Adding a Device
1. Open **Fleet > Devices** from the left sidebar.
2. Click **+ Onboard New Device**.
3. Fill in:
   - **Hostname**: e.g., `core-router-01.dc1`
   - **IP Address**: Management IP (`10.0.0.1` or public IPv4/IPv6)
   - **Protocol**: `MikroTik API`, `SNMP v2c`, `SNMP v3`, or `SSH`
   - **Credentials**: Select existing credential profile or create a new vault entry.
4. Click **Verify & Save**. The platform will immediately query the device and pull interface inventory.

---

## 3. Real-Time Telemetry & Traffic Ingestion

### 3.1 Interface Bandwidth & Charts
- Navigate to **Network > Bandwidth Management** or **Fleet > Interfaces**.
- Click on any interface to view microsecond-resolution TX/RX bandwidth graphs.
- **95th Percentile Calculation**: View automated 95th percentile billing curves for transit circuits.

### 3.2 NetFlow & sFlow Analyzer
- Configure your routers to export NetFlow/sFlow to the server:
  - **NetFlow Port**: `2055` (UDP)
  - **sFlow Port**: `6343` (UDP)
- Go to **Analytics > Pop Bandwidth Center** to inspect:
  - Top Talkers by IP & Port
  - ASN Traffic Matrix (Google, Cloudflare, Meta, Akamai, Local IX)
  - Application Protocol Distribution

---

## 4. BGP Peering & Routing Visibility

- Open **Network > BGP**.
- View all upstream transit peers and IX peering sessions:
  - **BGP State**: `Established`, `Active`, `Idle`, `Connect`
  - **Prefix Count**: Total prefixes accepted / advertised
  - **Uptime / Flaps**: History of BGP session resets
- The system automatically triggers an urgent Telegram alert if any core peer enters non-established state.

---

## 5. Autonomous DDoS Protection & Mitigation

- Open **Security > DDoS Protection**.
- **Anomaly Detection**: FastNetMon actively analyzes incoming flow packets against configured packet-per-second (PPS) and bandwidth (MBps) thresholds.
- **BGP Blackholing**:
  - When an attack is detected on a specific target IP (e.g. `103.x.x.x`), the system can automatically inject a `/32` blackhole route via BGP community to discard traffic at the upstream border.
- **Manual Overrides**: Operators can manually trigger or release blackhole states with a single click.

---

## 6. IP Address Management (IPAM)

- Navigate to **IPAM > Prefixes & Aggregates**.
- Manage IPv4/IPv6 address space with visual subnet utilization bars.
- **VLAN Manager**: Map 802.1Q VLAN IDs across POPs and distribution switches.
- **MAC & IP Tracer**: Locate the exact switch port and VLAN for any subscriber or rogue device.

---

## 7. Automated Configuration Backup Vault

- Open **Operations > Backup Vault** or **Operations > Device Configuration**.
- **Nightly Snapshots**: Core engine automatically fetches router configs daily at 03:00 AM.
- **Visual Diffing**: Select two backup timestamps to view an instant side-by-side green/red syntax diff.
- **Rollback**: Download or push previous configuration revisions back to the router via SSH/API.

---

## 8. Alerting & Telegram Notifications

1. Navigate to **Automation > Alerts Bot**.
2. Set your **Telegram Bot Token** and **Target Group Chat ID**.
3. Toggle alert categories:
   - 🔴 Critical: Router Down, BGP Session Down, DDoS Alert
   - 🟡 Warning: High CPU (>85%), High Memory, Interface Packet Drops
   - 🟢 Info: Backup Succeeded, Daily Health Report
4. Click **Send Test Notification**.

---

## 9. Platform Diagnostics & Maintenance

- **Health Endpoint**: Test platform status via terminal:
  ```bash
  curl -k https://<server-ip>/api/v2/health
  ```
- **Cluster Management & Service Restarts**:
  ```bash
  # Restart Web API Cluster (Tier-B: 5 Instances)
  sudo systemctl restart nms_engine@{8000..8004}

  # Restart Polling Worker Cluster (Tier-A: 3 Instances)
  sudo systemctl restart nms_worker@{9000..9002}

  # Verify HA Cluster Health & Status
  sudo bash /usr/local/bin/verify-ha.sh
  ```
- **Live Logs Inspection**:
  ```bash
  # Web API engine logs
  sudo journalctl -u 'nms_engine@*' -f

  # Polling worker engine logs
  sudo journalctl -u 'nms_worker@*' -f
  ```
