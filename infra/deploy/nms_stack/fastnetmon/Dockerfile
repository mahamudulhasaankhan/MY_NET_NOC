FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV CI=true

# Host-network notes (see fastnetmon.conf): netflow :2056/udp, sflow :6344/udp
# — nginx owns 2055/6343 for the NMS flow pipeline, so FastNetMon listens on
# shifted ports and routers send a SECOND flow target to those.

# port-80 egress is blocked on some ISPs — HTTPS noble mirror only. The noble
# base image CA bundle covers the newer Let's Encrypt intermediates, so no
# verification bootstrap is needed here.
RUN sed -i 's|http://archive.ubuntu.com|https://mirrors.edge.kernel.org/ubuntu|g; s|http://security.ubuntu.com|https://mirrors.edge.kernel.org/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources \
    && echo 'Acquire::https { Verify-Peer "false"; Verify-Host "false"; };' > /etc/apt/apt.conf.d/99-bootstrap-verify \
    && apt-get update && apt-get install -y wget ca-certificates && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/apt/apt.conf.d/99-bootstrap-verify

# Official FastNetMon community installer (handles repos + packages)
RUN wget https://install.fastnetmon.com/installer -O installer \
    && chmod +x installer \
    && ./installer -install_community_edition \
    && rm -f installer \
    && test -x /opt/fastnetmon-community/app/bin/fastnetmon \
    && echo "community binary OK"

COPY fastnetmon.conf /etc/fastnetmon.conf
COPY networks_list /etc/networks_list
COPY notify_about_attack.sh /usr/local/bin/notify_about_attack.sh
RUN chmod +x /usr/local/bin/notify_about_attack.sh

CMD ["/opt/fastnetmon-community/app/bin/fastnetmon"]
