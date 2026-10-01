#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"
FIXTURES="$ROOT/tests/fixtures"

PLAIN_STAGES="00-repos 20-snapper 30-packages 40-system 45-auth 50-user 55-agents 60-gaming 65-login-manager 70-verify"
MAC_STAGES="00-repos 20-snapper 15-mac 30-packages 40-system 45-auth 50-user 55-agents 60-gaming 65-login-manager 70-verify"
NVIDIA_STAGES="00-repos 20-snapper 10-nvidia 30-packages 40-system 45-auth 50-user 55-agents 60-gaming 65-login-manager 70-verify"

on_hardware() {
  local fixture="$1"; shift
  VEKRONA_SYSFS_ROOT="$FIXTURES/$fixture" "$@"
}

expect() {
  local fixture="$1" want="$2"; shift 2
  local got=false
  if on_hardware "$fixture" "$@"; then got=true; fi
  [[ "$got" == "$want" ]] || die "$fixture: '$*' returned $got, expected $want"
}

expect_output() {
  local fixture="$1" want="$2"; shift 2
  local got
  got="$(on_hardware "$fixture" "$@" | paste -sd' ')"
  [[ "$got" == "$want" ]] || die "$fixture: '$*' printed '$got', expected '$want'"
}

expect_stages() {
  local fixture="$1" want="$2" got
  got="$(VEKRONA_SYSFS_ROOT="$FIXTURES/$fixture" "$ROOT/install.sh" --list | paste -sd' ')"
  [[ "$got" == "$want" ]] || die "$fixture: install.sh --list printed '$got', expected '$want'"
}

expect_predicates() {
  local fixture="$1" \
    nvidia_gpu="$2" apple="$3" broadcom_wl="$4" brcmfmac_43602="$5" facetime="$6" gmux="$7" laptop="$8" \
    nvidia_stage="$9" mac_stage="${10}" dgpu_udev="${11}" usb_autosuspend="${12}" mbp12_1="${13}"
  expect "$fixture" "$nvidia_gpu" has_nvidia_gpu
  expect "$fixture" "$apple" is_apple_mac
  expect "$fixture" "$broadcom_wl" has_broadcom_wl_wifi
  expect "$fixture" "$brcmfmac_43602" has_brcmfmac_43602
  expect "$fixture" "$facetime" has_facetime_hd_camera
  expect "$fixture" "$gmux" has_apple_gmux_dual_gpu
  expect "$fixture" "$mbp12_1" is_macbookpro12_1
  expect "$fixture" "$laptop" is_laptop
  expect "$fixture" "$nvidia_stage" wants_nvidia_stage
  expect "$fixture" "$nvidia_stage" stage_applies 10-nvidia
  expect "$fixture" "$mac_stage" stage_applies 15-mac
  expect "$fixture" true stage_applies 30-packages
  expect "$fixture" "$dgpu_udev" wants_dgpu_udev_rule
  expect "$fixture" "$usb_autosuspend" wants_usb_autosuspend_dropin
  log "ok: $fixture predicates"
}

#                  fixture          nvidia apple  wl     43602  camera gmux   laptop nv-st  mac-st dgpu   usb-as mbp12,1
expect_predicates macbookpro11-1    false  true   true   false  true   false  true   false  true   false  false  false
expect_predicates macbookpro11-3    true   true   true   false  true   true   true   false  true   false  false  false
expect_predicates macbookpro12-1    false  true   false  true   true   false  true   false  true   false  false  true
expect_predicates desktop-nvidia    true   false  false  false  false  false  false  true   false  true   true  false
expect_predicates laptop-generic    false  false  false  false  false  false  true   false  false  false  false  false

expect macbookpro11-3 true pci_has_id 10de:0fe9
expect macbookpro11-3 false pci_has_id 10de:ffff
expect macbookpro11-3 false pci_has_id 14e4:43ba

expect_output macbookpro11-1 "0x8086" pci_display_vendors
expect_output macbookpro11-3 "0x8086 0x10de" pci_display_vendors
expect_output desktop-nvidia "0x8086 0x10de" pci_display_vendors
expect_output laptop-generic "0x8086" pci_display_vendors

[[ "$(on_hardware macbookpro12-1 dmi_field product_name)" == "MacBookPro12,1" ]] || die "dmi_field product_name wrong for macbookpro12-1"
[[ "$(on_hardware laptop-generic dmi_field sys_vendor)" == "LENOVO" ]] || die "dmi_field sys_vendor wrong for laptop-generic"
[[ -z "$(on_hardware laptop-generic dmi_field no_such_field)" ]] || die "dmi_field must print nothing for a missing field"
log "ok: pci_has_id, pci_display_vendors, dmi_field"

expect_stages macbookpro11-1 "$MAC_STAGES"
expect_stages macbookpro11-3 "$MAC_STAGES"
expect_stages macbookpro12-1 "$MAC_STAGES"
expect_stages desktop-nvidia "$NVIDIA_STAGES"
expect_stages laptop-generic "$PLAIN_STAGES"
log "ok: install.sh --list per hardware"

HOOK="$ROOT/etc/systemd/system-sleep/vekrona-brcmfmac-resume"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/modprobe" <<'FAKE'
#!/usr/bin/env bash
echo "modprobe $*" >> "$FAKE_LOG"
[[ -z "${FAKE_MODPROBE_FAIL:-}" ]] || { echo "$FAKE_MODPROBE_FAIL" >&2; exit 1; }
FAKE
cat > "$work/bin/logger" <<'FAKE'
#!/usr/bin/env bash
echo "logger $*" >> "$FAKE_LOG"
FAKE
chmod +x "$work/bin/modprobe" "$work/bin/logger"

run_hook() {
  : > "$work/log"
  FAKE_LOG="$work/log" PATH="$work/bin:$PATH" "$HOOK" "$@"
}

run_hook pre suspend
[[ ! -s "$work/log" ]] || die "hook must do nothing before suspend, did: $(<"$work/log")"

run_hook post suspend
grep -qx 'modprobe -r brcmfmac_wcc brcmfmac' "$work/log" || die "hook did not unload brcmfmac on resume"
grep -qx 'modprobe brcmfmac' "$work/log" || die "hook did not reload brcmfmac on resume"

failure=0
FAKE_MODPROBE_FAIL="Module brcmfmac is in use" run_hook post suspend || failure=$?
[[ "$failure" -ne 0 ]] || die "hook must fail when the module cannot be reloaded"
grep -q 'logger --priority daemon.err .*Module brcmfmac is in use' "$work/log" || die "hook did not log the modprobe failure to the journal"
log "ok: brcmfmac resume hook reloads on resume and logs failures"
