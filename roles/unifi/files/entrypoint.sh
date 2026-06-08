#!/usr/bin/env bash
# Foreground launcher for the UniFi Network Application.
#
# `ace.jar start` boots the embedded MongoDB and runs the controller in the
# foreground, so the host's systemd (via the Quadlet) owns the process
# lifecycle directly instead of an in-container init. This makes Restart=,
# journald logging, and `systemctl --user status` behave correctly.
set -euo pipefail

exec java \
  -Dunifi.datadir=/var/lib/unifi \
  -Dunifi.logdir=/var/log/unifi \
  -Dunifi.rundir=/var/run/unifi \
  -jar /usr/lib/unifi/lib/ace.jar start
