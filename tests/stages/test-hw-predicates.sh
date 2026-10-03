#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"
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
    nvidia_stage="$9" mac_stage="${10}" usb_autosuspend="${11}" mbp12_1="${12}"
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
  expect "$fixture" "$usb_autosuspend" wants_usb_autosuspend_dropin
  log "ok: $fixture predicates"
}

#                  fixture          nvidia apple  wl     43602  camera gmux   laptop nv-st  mac-st usb-as mbp12,1
expect_predicates macbookpro11-1    false  true   true   false  true   false  true   false  true   false  false
expect_predicates macbookpro11-3    true   true   true   false  true   true   true   false  true   false  false
expect_predicates macbookpro12-1    false  true   false  true   true   false  true   false  true   false  true
expect_predicates desktop-nvidia    true   false  false  false  false  false  false  true   false  true   false
expect_predicates laptop-generic    false  false  false  false  false  false  true   false  false  false  false
expect_predicates desktop-pascal    true   false  false  false  false  false  false  false  false  true   false
expect_predicates laptop-optimus-pascal true false false false false false true  false  false  false  false
expect_predicates laptop-optimus-turing true false false false false false true  true   false  false  false
expect_predicates desktop-volta     true   false  false  false  false  false  false  false  false  true   false
expect_predicates desktop-blackwell true   false  false  false  false  false  false  false  false  true   false
expect_predicates desktop-mixed     true   false  false  false  false  false  false  false  false  true   false

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
expect_stages desktop-pascal "$PLAIN_STAGES"
expect_stages laptop-optimus-pascal "$PLAIN_STAGES"
expect_stages laptop-optimus-turing "$NVIDIA_STAGES"
expect_stages desktop-volta "$PLAIN_STAGES"
expect_stages desktop-blackwell "$PLAIN_STAGES"
expect_stages desktop-mixed "$PLAIN_STAGES"
log "ok: install.sh --list per hardware"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- NVIDIA stage gating: supported PCI ID range ---

lone_gpu="$work/lone-gpu"
mkdir -p "$lone_gpu/sys/bus/pci/devices/0000:01:00.0"
printf '0x10de\n' > "$lone_gpu/sys/bus/pci/devices/0000:01:00.0/vendor"
printf '0x030000\n' > "$lone_gpu/sys/bus/pci/devices/0000:01:00.0/class"

# Prints the unsupported IDs for a machine whose only NVIDIA GPU has the given device ID file content.
unsupported_for() {
  printf '%s\n' "$1" > "$lone_gpu/sys/bus/pci/devices/0000:01:00.0/device"
  VEKRONA_SYSFS_ROOT="$lone_gpu" unsupported_nvidia_ids
}

expect_supported() { [[ -z "$(unsupported_for "$1")" ]] || die "NVIDIA device $1 ($2) is refused, expected supported"; }
expect_unsupported() { [[ "$(unsupported_for "$1")" == "10de:${1#0x}" ]] || die "NVIDIA device '$1' ($2) is not refused"; }

expect_supported 0x1e02 "Turing TU102"
expect_supported 0x1e82 "Turing TU104"
expect_supported 0x1f02 "Turing TU106"
expect_supported 0x1f82 "Turing TU117"
expect_supported 0x2182 "Turing TU116"
expect_supported 0x2684 "Ada AD102"
expect_supported 0x28e0 "Ada AD107"
expect_supported 0x1E00 "lowest supported ID in upper case"
expect_supported 0x28ff "highest supported ID"
expect_unsupported 0x1db4 "Volta"
expect_unsupported 0x1d81 "Titan V"
expect_unsupported 0x1b80 "Pascal"
expect_unsupported 0x1c8c "Pascal"
expect_unsupported 0x1d01 "Pascal GP108"
expect_unsupported 0x0fe9 "Kepler"
expect_unsupported 0x1dff "just below Turing"
expect_unsupported 0x2900 "lowest Blackwell-era ID"
expect_unsupported 0x2b85 "Blackwell"
expect_unsupported 0x2c02 "Blackwell"
expect_unsupported 0x2f04 "Blackwell"
expect_unsupported 0xffff "highest possible ID"
expect_unsupported 0x0000 "lowest possible ID"
expect_unsupported lizard "malformed ID fails closed"
expect_unsupported "" "empty ID fails closed"
expect_unsupported 0x1e0 "truncated ID fails closed"
log "ok: only Turing..Ada NVIDIA IDs are supported"

# --- NVIDIA stage gating: Secure Boot ---

sb_root="$work/secure-boot"
mkdir -p "$sb_root/bin" "$sb_root/sys/firmware/efi" "$sb_root/etc/pki/akmods/certs"
akmods_key="$sb_root$AKMODS_PUBLIC_KEY"
touch "$akmods_key"

# mokutil answers --sb-state with $MOK_SB (exit $MOK_SB_STATUS) and --test-key with $MOK_KEY (exit $MOK_KEY_STATUS).
cat > "$sb_root/bin/mokutil" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --sb-state) printf '%s\n' "${MOK_SB-}"; exit "${MOK_SB_STATUS:-0}" ;;
  --test-key) printf '%s\n' "${MOK_KEY-}"; exit "${MOK_KEY_STATUS:-0}" ;;
esac
exit 2
FAKE
chmod +x "$sb_root/bin/mokutil"
mkdir "$sb_root/empty-bin"

with_mokutil() { PATH="$sb_root/bin:$PATH" VEKRONA_SYSFS_ROOT="$sb_root" "$@"; }

expect_sb_fine() { # expect_sb_fine <what>
  local problem
  problem="$(with_mokutil secure_boot_problem)"
  [[ -z "$problem" ]] || die "$1: Secure Boot reported '$problem', expected nothing"
}

expect_sb_problem() { # expect_sb_problem <what> <substring of the reason>
  local problem
  problem="$(with_mokutil secure_boot_problem)"
  [[ "$problem" == *"$2"* ]] || die "$1: Secure Boot reported '$problem', expected it to contain '$2'"
}

MOK_SB="SecureBoot enabled" MOK_KEY="$AKMODS_PUBLIC_KEY is not enrolled" MOK_KEY_STATUS=1 \
  expect_sb_problem "Secure Boot on, akmods key not enrolled" "akmods key $AKMODS_PUBLIC_KEY is not enrolled"
MOK_SB="SecureBoot enabled" MOK_KEY="$AKMODS_PUBLIC_KEY is already enrolled" \
  expect_sb_fine "Secure Boot on, akmods key enrolled"
MOK_SB="SecureBoot disabled" MOK_KEY="is not enrolled" expect_sb_fine "Secure Boot off"
MOK_SB="$(printf 'SecureBoot disabled\nPlatform is in Setup Mode')" expect_sb_fine "Secure Boot off in Setup Mode (real RTX 4090 machine output)"
MOK_SB="This system doesn't support Secure Boot" MOK_SB_STATUS=1 expect_sb_fine "firmware without Secure Boot support"

rm "$akmods_key"
MOK_SB="SecureBoot enabled" MOK_KEY="is already enrolled" \
  expect_sb_problem "Secure Boot on, akmods key file absent" "is not enrolled"
touch "$akmods_key"

MOK_SB="SecureBoot enabled" MOK_KEY="" MOK_KEY_STATUS=1 \
  expect_sb_problem "Secure Boot on, silent failing mokutil --test-key" "cannot verify the akmods key"
MOK_SB="Failed to read SecureBoot" MOK_SB_STATUS=1 \
  expect_sb_problem "failing mokutil --sb-state" "mokutil --sb-state failed (Failed to read SecureBoot), cannot verify"
MOK_SB="gibberish" expect_sb_problem "unrecognised mokutil --sb-state output" "unexpected mokutil --sb-state output (gibberish)"

problem="$(PATH="$sb_root/empty-bin" VEKRONA_SYSFS_ROOT="$sb_root" secure_boot_problem)"
[[ "$problem" == *"mokutil is not installed, cannot verify Secure Boot"*"sudo dnf install mokutil"* ]] || die "a missing mokutil reported '$problem'"

rmdir "$sb_root/sys/firmware/efi"
MOK_SB="SecureBoot enabled" MOK_KEY="is not enrolled" expect_sb_fine "a legacy BIOS boot has no Secure Boot"
PATH="$sb_root/empty-bin" VEKRONA_SYSFS_ROOT="$sb_root" secure_boot_problem | grep -q . && die "a legacy BIOS boot needed mokutil"
mkdir "$sb_root/sys/firmware/efi"
log "ok: Secure Boot blocks akmods only when enabled and the key is not enrolled; an unverifiable state refuses with its reason"

# A supported GPU is still refused when Secure Boot would stop its module.
printf "0x2684\n" > "$lone_gpu/sys/bus/pci/devices/0000:01:00.0/device"
cp -r "$lone_gpu/sys/bus" "$sb_root/sys/"
expect_wants_stage() { # expect_wants_stage <true|false> <what>
  local got=false
  if with_mokutil wants_nvidia_stage; then got=true; fi
  [[ "$got" == "$1" ]] || die "$2: wants_nvidia_stage returned $got, expected $1"
}
MOK_SB="SecureBoot enabled" MOK_KEY="is not enrolled" expect_wants_stage false "Secure Boot on, key not enrolled"
MOK_SB="SecureBoot enabled" MOK_KEY="is already enrolled" expect_wants_stage true "Secure Boot on, key enrolled"
MOK_SB="SecureBoot disabled" expect_wants_stage true "Secure Boot off"
MOK_SB="" MOK_SB_STATUS=1 expect_wants_stage false "Secure Boot state unverifiable"
log "ok: wants_nvidia_stage follows Secure Boot"

# --- install.sh reports a refused NVIDIA stage once ---

expect_refusal_warning() { # expect_refusal_warning <fixture> <substring>; naming the refused stage dies before any stage runs
  local warnings
  warnings="$(VEKRONA_SYSFS_ROOT="$FIXTURES/$1" "$ROOT/install.sh" 10-nvidia 2>&1 >/dev/null || true)"
  [[ "$(grep -c 'keeping nouveau' <<<"$warnings")" == 1 && "$warnings" == *"$2"* ]] \
    || die "$1: install.sh warned '$warnings', expected one 'keeping nouveau' warning containing '$2'"
}

expect_no_warning() {
  local warnings
  warnings="$(VEKRONA_SYSFS_ROOT="$FIXTURES/$1" "$ROOT/install.sh" --list 2>&1 >/dev/null)"
  [[ -z "$warnings" ]] || die "$1: install.sh warned '$warnings', expected nothing"
}

expect_refusal_warning desktop-pascal 10de:1b80
expect_refusal_warning laptop-optimus-pascal 10de:1c8c
expect_refusal_warning desktop-volta 10de:1db4
expect_refusal_warning desktop-blackwell 10de:2b85
expect_refusal_warning desktop-mixed 10de:1b80
for listing in "--list" "--list 10-nvidia" "--list 30-packages"; do
  # shellcheck disable=SC2086
  [[ "$(VEKRONA_SYSFS_ROOT="$FIXTURES/desktop-pascal" "$ROOT/install.sh" $listing 2>&1 >/dev/null || true)" != *"keeping nouveau"* ]] \
    || die "install.sh $listing must not warn about a refused NVIDIA stage"
done
expect_no_warning desktop-nvidia
expect_no_warning laptop-optimus-turing
expect_no_warning laptop-generic
expect_no_warning macbookpro11-3
log "ok: install.sh warns once, with the device IDs, when it keeps nouveau"

HOOK="$ROOT/etc/systemd/system-sleep/vekrona-brcmfmac-resume"
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
