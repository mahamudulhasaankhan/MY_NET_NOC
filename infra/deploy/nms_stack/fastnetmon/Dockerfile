FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    wget \
    curl \
    gnupg2 \
    ca-certificates \
    iproute2 \
    python3 \
    && rm -rf /var/lib/apt/lists/*

RUN wget https://install.fastnetmon.com/installer -Oinstaller
# For the purpose of Docker, we might need a custom install or just run the installer.
# FastNetMon Community installer script installs systemd services which won't work easily in basic Docker without systemd.
# A simpler approach for a demo/placeholder:
CMD ["sleep", "infinity"]
