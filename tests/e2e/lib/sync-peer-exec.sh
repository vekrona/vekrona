#!/usr/bin/env bash
# Runs in the guest, written there by sync-peer.sh. usage: lib/sync-peer-exec.sh NETNS HOME PIDFILE COMMAND...
# Runs COMMAND as the desktop user inside the network namespace NETNS, with HOME as the other device's home (so that the
# XDG directories fall under it) and the user's session bus, and records the PID of COMMAND itself in PIDFILE, so that the
# scenario can stop that process and nothing else.
set -euo pipefail
netns="$1" home="$2" pidfile="$3"
shift 3
uid="$(id -u)"
exec sudo ip netns exec "$netns" sudo -u "$USER" env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
  "HOME=$home" "XDG_RUNTIME_DIR=/run/user/$uid" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" "PATH=$PATH" \
  bash -c 'echo $$ >"$1"; shift; exec "$@"' _ "$pidfile" "$@"
