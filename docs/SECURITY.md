# 🛡️ Enterprise Security Policy & Architecture Guide

[![Security Posture](https://img.shields.io/badge/Security-Carrier--Grade%20Hardened-green.svg?style=for-the-badge&logo=shield)](https://github.com/mahamudulhasaankhan/MY_NET_NOC)
[![WAF Protection](https://img.shields.io/badge/Edge%20WAF-OWASP%20Top%2010%20Hardened-blue.svg?style=for-the-badge)](docs/USER_GUIDE.md)
[![Encryption](https://img.shields.io/badge/Encryption-AES--256--GCM%20Authenticated-red.svg?style=for-the-badge)](docs/API_REFERENCE.md)
[![Lead Architect](https://img.shields.io/badge/Lead%20Architect-Md.%20Mahamudul%20Hassan%20Khan-0A66C2?style=for-the-badge&logo=linkedin)](https://www.linkedin.com/in/md-mahamudul-hassan-khan/)

**MY_NET Enterprise NOC** is designed from the ground up to meet the stringent security, isolation, and compliance demands of modern Internet Service Providers, Telcos, and Financial Network Infrastructure.

---

## 🏛️ 6-Layer Enterprise Defense Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. EDGE PERIMETER DEFENSE & WAF                                         │
│    • TLS 1.3 / 1.2 Strict Encryption with Perfect Forward Secrecy (PFS) │
│    • OWASP Top 10 WAF (SQLi, XSS, Path Traversal & Bot Heuristics)       │
│    • Token Bucket Rate Limiting & DoS mitigation per IP subnet          │
├─────────────────────────────────────────────────────────────────────────┤
│ 2. ZERO-TRUST IDENTITY & RBAC                                           │
│    • Time-based One-Time Password (TOTP / 2FA) multi-factor auth (RFC 6238)│
│    • Granular Role-Based Access Control (SuperAdmin, Operator, Auditor) │
│    • Cryptographically signed JWT tokens with microsecond revocation    │
├─────────────────────────────────────────────────────────────────────────┤
│ 3. CREDENTIAL VAULT & ENCRYPTION AT REST                                │
│    • Router SSH, SNMP v3 & API secrets encrypted with AES-256-GCM       │
│    • Authenticated encryption with unique 12-byte initialization vectors│
│    • Zero-leakage: Secrets are masked in logs and excluded from APIs    │
├─────────────────────────────────────────────────────────────────────────┤
│ 4. MEMORY SAFETY & PROCESS SANDBOXING                                   │
│    • Type-safe Go core engine eliminating buffer overflows & memory leaks│
│    • Linux systemd isolation (NoNewPrivileges=yes, PrivateTmp=yes)      │
│    • Kernel cgroups enforcing CPU quotas and strict memory boundaries   │
├─────────────────────────────────────────────────────────────────────────┤
│ 5. AUTONOMOUS DDOS & NETWORK FABRIC ISOLATION                           │
│    • FastNetMon inline volumetric anomaly inspection                    │
│    • Automated BGP /32 blackhole dispatches to upstream transit         │
│    • Database tier isolated within private Docker bridge networks       │
├─────────────────────────────────────────────────────────────────────────┤
│ 6. IMMUTABLE AUDIT TRAILS & EVENT LOGGING                               │
│    • Tamper-evident logging of every configuration push & user action   │
│    • High-density ClickHouse storage for real-time security forensics   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 🔒 Deep Security Capabilities

### 1. Edge Web Application Firewall (WAF)
- **SSL/TLS Hardening**: Enforces modern cipher suites (`ECDHE-ECDSA-AES256-GCM-SHA384`, `TLS_AES_256_GCM_SHA384`) with HTTP Strict Transport Security (HSTS) headers.
- **Payload Inspection**: Rejects malformed requests, SQL injection signatures (`UNION`, `SELECT`, `--`), and script injection vectors before they reach application workers.
- **Anti-Scraping & Bad Bots**: Blocks malicious user-agents and aggressive automated scanners.

### 2. Cryptographic Credential Vault
- Every stored credential (router passwords, SNMP community strings, API tokens) is encrypted using **AES-256-GCM (Galois/Counter Mode)**.
- GCM provides both **confidentiality** and **authenticity**, guaranteeing that ciphertext cannot be altered or forged without immediate detection.

### 3. High Availability & Denial-of-Service Resistance
- **Cluster Redundancy**: 8-instance split-role dual-tier cluster (5 Web API + 3 Polling Workers) with sub-second failover prevents service outages during node stress.
- **Volumetric Flood Defense**: Integrated FastNetMon flow analysis monitors packets-per-second (PPS) and bandwidth thresholds, automatically triggering BGP community-based blackholing to protect upstream transit links.

### 4. Zero-Trust Access & Auditing
- **TOTP 2FA**: Mandatory two-factor authentication for administrative operations.
- **Audit Logging**: Every device modification, backup restore, or user permission change is permanently recorded with timestamp, operator ID, and IP address.

---

## 📋 Security Best Practices for Production Deployments

For maximum security when deploying **MY_NET Enterprise NOC**:

1. **Firewall Ingress**: Restrict access to ports `443` (Web UI) and `2055/6343` (Flow Ingest). Keep database ports (`5432`, `6379`, `9001`) strictly on `127.0.0.1` or internal private VLANs.
2. **Master Secret Key**: Set a strong, unique 32-byte hexadecimal key in `/etc/nms/nms.env` (`ENCRYPTION_KEY`).
3. **Valid TLS Certificates**: Replace initial self-signed certificates with trusted CA or Let's Encrypt certificates for production domain names.
4. **SNMP v3 Enforcement**: Use SNMP v3 with `authPriv` (SHA authentication + AES privacy encryption) for all managed network hardware.

---

## 🛡️ Vulnerability Disclosure & Reporting Policy

We prioritize the security of our users and welcome responsible vulnerability reports.

If you discover a potential security flaw:
1. **Do not disclose the issue publicly** or create public issues on GitHub.
2. Send a detailed report directly to the lead architect:
   - **Lead Architect & Creator**: [**Md. Mahamudul Hassan Khan**](https://www.linkedin.com/in/md-mahamudul-hassan-khan/)
   - **Security Contact**: `security@nms.local`
3. Include:
   - Vulnerability classification and estimated severity.
   - Exact steps or proof-of-concept (PoC) to reproduce the behavior.
   - Affected endpoints or parameters.

### SLA & Remediation Commitment
- **Acknowledgment**: Within 24 hours.
- **Triage & Patch**: Critical vulnerabilities are patched and hotfixed within 48 to 72 hours.
- **Responsible Disclosure**: Coordinated public disclosure only after an official patch release is distributed.

---

## ⚖️ Intellectual Property & Compliance

Security architecture and implementation designed and maintained by **[Md. Mahamudul Hassan Khan](https://www.linkedin.com/in/md-mahamudul-hassan-khan/)**.  
Licensed under **GNU AGPLv3 with Mandatory Attribution**.
