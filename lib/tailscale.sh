#!/usr/bin/env bash
# What vekrona sets on tailscaled, and how it reads it back: stage 40-system sets it, 70-verify checks it.
# vekrona wants the operator (so `tailscale up` needs no sudo), shields up (no inbound connection from the tailnet: its NAT
# traversal needs no open port) and Tailscale SSH off (no remote shell). tailscaled keeps no setting across a restart until
# the node has a profile, that is until the first login: the drop-in etc/systemd/system/tailscaled.service.d/vekrona-hardening.conf
# sets shields up and ssh off at every start, the operator is only set by ensure_tailscale_settings.

# The functions below read the JSON of tailscale_prefs, which callers fetch once: every `tailscale debug prefs` is a call to tailscaled.
tailscale_prefs() { root tailscale debug prefs; }
tailscale_logged_out() { [[ "$(jq -r '.LoggedOut' <<<"$1")" == true ]]; }
tailscale_operator_is() { [[ "$(jq -r '.OperatorUser // ""' <<<"$1")" == "$2" ]]; }
tailscale_hardened() { [[ "$(jq -c '[.ShieldsUp, .RunSSH]' <<<"$1")" == '[true,false]' ]]; }
tailscale_settings_current() { tailscale_operator_is "$1" "$2" && tailscale_hardened "$1"; }

ensure_tailscale_settings() {
  local user="$1" prefs
  prefs="$(tailscale_prefs)" || die "cannot read the tailscale preferences"
  if tailscale_settings_current "$prefs" "$user"; then
    log "tailscale: operator $user, shields up, ssh off"
    return 0
  fi
  log "setting tailscale: operator $user, shields up, ssh off"
  root tailscale set --operator="$user" --shields-up=true --ssh=false
  prefs="$(tailscale_prefs)" || die "cannot read the tailscale preferences"
  tailscale_settings_current "$prefs" "$user" \
    || die "tailscale did not keep operator $user, shields up and ssh off: run 'tailscale up --shields-up --ssh=false', then ./install.sh 40"
}
