#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
RESTART_RECORD_REGEX="WirePlumber stopped reacting to devices and was restarted"
GUEST_SCRIPT_DIR='$HOME/.local/share/wireplumber/scripts'
GUEST_CONF_DIR='$HOME/.config/wireplumber/wireplumber.conf.d'

restart_recorded() { vekrona-dev run vekrona-error list --all | grep -q "$RESTART_RECORD_REGEX"; }
export -f restart_recorded
export RESTART_RECORD_REGEX

restart_wireplumber() { vekrona-dev run systemctl --user restart wireplumber.service; }

# The restart record this scenario provokes goes again, so that it does not stay unread in the store for the next one.
forget_restart_records() {
  vekrona-dev run bash -c 'vekrona-error list --all | grep "$1" | while read -r id _; do vekrona-error rm "$id"; done' _ "$RESTART_RECORD_REGEX"
  vekrona-dev run vekrona-error refresh-unread
}

cleanup() {
  forget_restart_records || warn "could not remove the restart record this scenario made"
  vekrona-dev run bash -c "rm -f $GUEST_SCRIPT_DIR/vekrona-test-wedge.lua $GUEST_CONF_DIR/zz-vekrona-test-wedge.conf" || warn "could not remove the wedge script from the guest"
  restart_wireplumber || warn "could not restart WirePlumber in the guest"
  audio_teardown
}

vekrona-dev session
vekrona-dev run systemctl --user is-active --quiet vekrona-audio-watchdog.service \
  || die "vekrona-audio-watchdog.service is not running"
audio_setup
trap cleanup EXIT

vekrona-dev run bash -c "mkdir -p $GUEST_SCRIPT_DIR $GUEST_CONF_DIR && cat >$GUEST_SCRIPT_DIR/vekrona-test-wedge.lua" <"$ROOT/tests/e2e/audio/vekrona-test-wedge.lua"
vekrona-dev run bash -c "cat >$GUEST_CONF_DIR/zz-vekrona-test-wedge.conf" <"$ROOT/tests/e2e/audio/zz-vekrona-test-wedge.conf"
restart_wireplumber
audio_stream_start
usb_audio_add
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- audio_graph_is "$USB_AUDIO_SINK" || die "the USB card did not become the default"
log "ok: the USB card is the default and the stream plays on it"

# The unplug is the event whose hook never completes: from here on WirePlumber ignores every device that comes or goes.
usb_audio_del
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- restart_recorded || die "WirePlumber was wedged by the unplug and no restart was recorded"
log "ok: the wedge was noticed, WirePlumber was restarted and the restart was recorded"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- audio_graph_is "$FALLBACK_SINK" \
  || die "after the restart, the default is not the remaining sink: $(vekrona-dev run python3 "$AUDIO_GUEST_STATE" --default-sink "$FALLBACK_SINK" --stream "$AUDIO_STREAM" 2>&1 || true)"
log "ok: after the restart the default and the stream are on the remaining sink"
