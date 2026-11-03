#!/usr/bin/env bash
# What vekrona sets on tailscaled, and how it reads it back: stage 40-system sets it, 70-verify checks it.
# vekrona wants the operator (so `tailscale up` needs no sudo), shields up (no inbound connection from the tailnet: its NAT
# traversal needs no open port) and Tailscale SSH off (no remote shell). tailscaled keeps no setting until the node has
# a profile, that is until the first login.

tailscale_prefs() { root tailscale debug prefs; }
tailscale_logged_out() { [[ "$(tailscale_prefs | jq -r '.LoggedOut')" == true ]]; }
tailscale_operator() { tailscale_prefs | jq -r '.OperatorUser // ""'; }
tailscale_hardened() { [[ "$(tailscale_prefs | jq -c '[.ShieldsUp, .RunSSH]')" == '[true,false]' ]]; }

ensure_tailscale_settings() {
  local user="$1"
  if [[ "$(tailscale_operator)" == "$user" ]] && tailscale_hardened; then
    log "tailscale: operator $user, shields up, ssh off"
    return 0
  fi
  log "setting tailscale: operator $user, shields up, ssh off"
  root tailscale set --operator="$user" --shields-up=true --ssh=false
  [[ "$(tailscale_operator)" == "$user" ]] && tailscale_hardened \
    || die "tailscale did not keep operator $user, shields up and ssh off: run 'tailscale up --shields-up --ssh=false' to log in, then re-run ./install.sh 40"
}
