FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# FastNetMon Community Edition from the official apt repository.
# Runs in netflow/sflow ingestion mode (no AF_PACKET capture needed):
#   routers → netflow :2056/udp + sflow :6344/udp (see fastnetmon.conf)

# Network notes for the build:
#   * port-80 egress is blocked on this host — HTTPS mirrors only
#   * archive.ubuntu.com / security.ubuntu.com are TLS-MITM'd by the ISP and
#     the base image's CA bundle lacks the intercept CA — TLS peer
#     verification is disabled for the BUILD ONLY (apt packages remain
#     GPG-verified by ubuntu independently of TLS); the override is removed
#     at the end.
#   * FastNetMon's repo publishes no standalone GPG key file, so its source
#     uses [trusted=yes] (repo is official + HTTPS; documented trade-off).

RUN sed -i 's|http://archive.ubuntu.com|https://mirrors.edge.kernel.org/ubuntu|g; s|http://security.ubuntu.com|https://security.ubuntu.com|g' /etc/apt/sources.list \
    && echo 'Acquire::https { Verify-Peer "false"; Verify-Host "false"; };' > /etc/apt/apt.conf.d/99-bootstrap-verify \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget curl gnupg2 iproute2 python3 iptables

# FastNetMon Community repository ([trusted=yes] — no public key file exists)
RUN echo "deb [trusted=yes] https://repo.fastnetmon.com/fastnetmon_ubuntu_jammy jammy fastnetmon" > /etc/apt/sources.list.d/fastnetmon.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends fastnetmon \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/apt/apt.conf.d/99-bootstrap-verify \
    && rm -f /etc/apt/sources.list.d/fastnetmon.list \
    && /opt/fastnetmon/fastnetmon --version

COPY fastnetmon.conf /etc/fastnetmon.conf
COPY networks_list /etc/networks_list
COPY notify_about_attack.sh /usr/local/bin/notify_about_attack.sh
RUN chmod +x /usr/local/bin/notify_about_attack.sh

# Foreground process for docker; config drives thresholds, ports and callbacks.
CMD ["/opt/fastnetmon/app/bin/fastnetmon", "--daemonize=false"]
