#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
GUEST_SIGNAL_LOG=/tmp/vekrona-e2e-signal.log
# shellcheck disable=SC2016 # $HOME expands in the guest
GUEST_CONFIG='$HOME/.var/app/org.signal.Signal/config/Signal/config.json'

config_has() { vekrona-dev sh bash -c "jq -e '$1' $GUEST_CONFIG >/dev/null 2>&1"; }
signal_window_open() { window_open org.signal.Signal; }
signal_stopped() { flatpak_stopped org.signal.Signal; }
keyring_has_signal() { vekrona-dev sh bash -c 'secret-tool search --all application Signal 2>&1 | grep -q "^attribute.application = Signal"'; }
config_lacks() { absent config_has "$1"; }
export -f config_has config_lacks signal_window_open signal_stopped keyring_has_signal
export GUEST_CONFIG

launch_signal() { vekrona-dev sh swaymsg exec "flatpak run org.signal.Signal >$GUEST_SIGNAL_LOG 2>&1" >/dev/null; }

stop_signal() {
  signal_stopped || vekrona-dev run flatpak kill org.signal.Signal
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- signal_stopped
}

vekrona-dev session
trap stop_signal EXIT
stop_signal
vekrona-dev run bash -c 'rm -rf ~/.var/app/org.signal.Signal/config/Signal'
! keyring_has_signal || vekrona-dev sh secret-tool clear application Signal

launch_signal
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- config_has '.safeStorageBackend'
backend="$(vekrona-dev sh bash -c "jq -r .safeStorageBackend $GUEST_CONFIG")"
[[ "$backend" == gnome_libsecret ]] || die "Signal must keep its key in gnome-keyring (gnome_libsecret), but its safeStorageBackend is $backend"
config_has '.encryptedKey' || die "Signal must store an encryptedKey, but config.json has none"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- keyring_has_signal
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- signal_window_open
text_absent 'plaintext password store' || die "Signal must not ask about the plaintext password store"
log "ok: Signal keeps its key in gnome-keyring and shows no plaintext dialog"

stop_signal
launch_signal
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- signal_window_open
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- config_lacks .key
absent vekrona-dev run grep -qiE "safeStorage backend|hmac check failed|decrypt" "$GUEST_SIGNAL_LOG" \
  || die "Signal must start again with the key it stored, but its log reports a key store error"
log "ok: Signal restarts with the key it stored in gnome-keyring"
