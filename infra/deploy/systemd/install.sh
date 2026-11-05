#!/bin/bash
# Install NMS HA stack (systemd units, env files, nginx configs, scripts)
# Usage: sudo ./install.sh
#
# Superseded by infra/deploy/scripts/bootstrap.sh (handles the full 5-instance HA
# stack + path portability). Kept as a compatibility entry point.
exec bash "$(dirname "$0")/../scripts/bootstrap.sh" "$@"
