#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
CYCLES=5
BURST=12
# QEMU's emulated xHCI controller reports errors of its own when a card is removed in the middle of its enumeration, which
# the burst provokes; they say nothing about the audio stack.
error_rows() { vekrona-dev run vekrona-error list --all | { grep -v 'kernel: xhci_hcd ' || [[ $? -eq 1 ]]; }; }

vekrona-dev session
audio_setup
trap audio_teardown EXIT
errors_before="$(error_rows | wc -l)"
since="$(vekrona-dev run date +%s)"

audio_stream_start
audio_expect "$FALLBACK_SINK" "the stream did not start on the only card"
log "ok: with only the onboard card, the stream plays on it"

usb_audio_add
audio_expect "$USB_AUDIO_SINK" "the USB card did not become the default"
log "ok: the USB card becomes the default and the stream follows it"

# A profile stored as off is what an earlier stall, or a click in a mixer, leaves behind.
vekrona-dev run bash -c 'wpctl set-profile "$1" 0' _ "$(usb_card_id)"
audio_expect "$FALLBACK_SINK" "switching the USB card off did not move the stream to the onboard card" --cards-may-be-off
usb_audio_del
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- usb_card_unlisted

for cycle in $(seq 1 "$CYCLES"); do
  audio_expect "$FALLBACK_SINK" "cycle $cycle: with the USB card away, the default is not the onboard card"
  usb_audio_add
  audio_expect "$USB_AUDIO_SINK" "cycle $cycle: the returning USB card did not become the default again"
  usb_audio_del
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- usb_card_unlisted
done
audio_expect "$FALLBACK_SINK" "after $CYCLES cycles, the default is not the onboard card"
log "ok: $CYCLES plug and unplug cycles, the default follows with a profile off stored for the USB card"

for _ in $(seq 1 "$BURST"); do
  usb_audio_add
  usb_audio_del
done
usb_audio_add
audio_expect "$USB_AUDIO_SINK" "after a burst of $BURST quick plugs, the USB card did not become the default"
# Stores the usable profile over the off this test stored, so the next run starts from a clean state.
# Setting the profile it already has stores nothing, so it goes off and back.
vekrona-dev run bash -c 'wpctl set-profile "$1" 0 && wpctl set-profile "$1" 1' _ "$(usb_card_id)"
# WirePlumber writes the stored profile to disk a moment later, and a restart before that would lose it.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev run bash -c 'grep -q "USB_Audio.*=output:analog-stereo" "$HOME/.local/state/wireplumber/default-profile"'
usb_audio_del
audio_expect "$FALLBACK_SINK" "after a burst of $BURST quick plugs, the default did not return to the onboard card"
log "ok: a burst of $BURST quick plugs and unplugs leaves the default and the stream right"

shell_errors_during="$(shell_log_since_matching "$since" 'ERROR|WARN.*audio')"
[[ -z "$shell_errors_during" ]] || die "vekrona-shell logged errors while the output came and went: $shell_errors_during"
errors_after="$(error_rows | wc -l)"
[[ "$errors_after" == "$errors_before" ]] || die "the error store grew during the test: $(error_rows)"
log "ok: the shell logged no errors and no error was recorded"
