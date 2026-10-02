#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"
report_error_for_die() { :; }  # die must not write into the real error journal

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/proc" "$work/boot" "$work/etc/kernel" "$work/etc/dracut.conf.d"
export VEKRONA_SYSFS_ROOT="$work"

# Fakes: grubby keeps its args in $work/grubby-args and logs updates; lsinitrd prints $LSINITRD_OUT;
# modinfo answers -F license from $MODINFO_LICENSE and -n from $MODINFO_PATH (exit 1 when unset).
cat > "$work/bin/grubby" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --info=ALL)
    printf '%s' "${GRUBBY_INFO-args=\"$(cat "$VEKRONA_SYSFS_ROOT/grubby-args")\"}"$'\n'
    exit "${GRUBBY_STATUS:-0}" ;;
  --update-kernel=ALL)
    echo "$*" >> "$VEKRONA_SYSFS_ROOT/grubby.log"
    [[ "${GRUBBY_UPDATE_STATUS:-0}" == 0 ]] || exit "$GRUBBY_UPDATE_STATUS"
    arg="${2#--args=}"
    sed -i "1 s/$/ $arg/" "$VEKRONA_SYSFS_ROOT/grubby-args"
    sed -i "1 s/$/ $arg/" "$VEKRONA_SYSFS_ROOT/etc/kernel/cmdline" ;;
esac
FAKE
cat > "$work/bin/lsinitrd" <<'FAKE'
#!/usr/bin/env bash
printf '%s' "${LSINITRD_OUT-}"
exit "${LSINITRD_STATUS:-0}"
FAKE
cat > "$work/bin/modinfo" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${MODINFO_LICENSE+x}" ]] || exit 1
case "$*" in
  *"-n nvidia"*) printf '%s\n' "$MODINFO_PATH" ;;
  *"-F license nvidia"*) printf '%s\n' "$MODINFO_LICENSE" ;;
esac
FAKE
cat > "$work/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == cat ]] || exit 2
printf '%s' "${SYSTEMCTL_OUT-}"
exit "${SYSTEMCTL_STATUS:-0}"
FAKE
cat > "$work/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
exec "$@"
FAKE
chmod +x "$work"/bin/*
PATH="$work/bin:$PATH"

BLACKLIST=rd.driver.blacklist=nouveau,nova_core

# --- nvidia_kernel_args ---

mkdir -p "$work/sys/class/dmi/id"
args_for_chassis() { # args_for_chassis <DMI chassis_type>
  printf '%s\n' "$1" > "$work/sys/class/dmi/id/chassis_type"
  nvidia_kernel_args | paste -sd' '
}

DESKTOP_ARGS="nvidia.NVreg_EnableGpuFirmware=0 pcie_aspm=off $BLACKLIST modprobe.blacklist=nouveau,nova_core"
LAPTOP_ARGS="nvidia.NVreg_EnableGpuFirmware=0 $BLACKLIST modprobe.blacklist=nouveau,nova_core"
[[ "$(args_for_chassis 3)" == "$DESKTOP_ARGS" ]] || die "a desktop does not get pcie_aspm=off: $(args_for_chassis 3)"
for chassis in 8 9 10 14; do
  [[ "$(args_for_chassis "$chassis")" == "$LAPTOP_ARGS" ]] || die "chassis $chassis (a laptop) got: $(args_for_chassis "$chassis")"
done
[[ "$(args_for_chassis "")" == "$DESKTOP_ARGS" ]] || die "an unknown chassis is not treated as a desktop: $(args_for_chassis "")"
log "ok: pcie_aspm=off only on desktops"

# --- kernel_arg_state ---

state_of() { # state_of <cmdline> <grubby args line> <arg>
  printf '%s\n' "$1" > "$work/proc/cmdline"
  GRUBBY_INFO="args=\"$2\""$'\n' kernel_arg_state "$3"
}

expect_state() {
  local want="$1" got
  got="$(state_of "$2" "$3" "$4")"
  [[ "$got" == "$want" ]] || die "'$4' with cmdline '$2' and grubby '$3' is '$got', expected '$want'"
}

expect_state active  "ro $BLACKLIST quiet" ""                 "$BLACKLIST"
expect_state pending "ro quiet"            "ro $BLACKLIST"    "$BLACKLIST"
expect_state missing "ro quiet"            "ro quiet"         "$BLACKLIST"
expect_state missing "ro quiet"            ""                 "$BLACKLIST"
log "ok: an arg is active, pending a reboot, or missing"

expect_state missing "rd.driver.blacklist=nouveau" "rd.driver.blacklist=nouveau" "$BLACKLIST"
expect_state missing "$BLACKLIST" "$BLACKLIST" "rd.driver.blacklist=nouveau"
expect_state missing "xrd.driver.blacklist=nouveau,nova_core" "" "$BLACKLIST"
expect_state missing "rdxdriver.blacklist=nouveau,nova_core" "" "$BLACKLIST"
log "ok: a token matches only whole, never as a prefix, suffix or regex"

printf 'ro quiet\n' > "$work/proc/cmdline"
if (GRUBBY_INFO="" GRUBBY_STATUS=1 kernel_arg_state "$BLACKLIST") 2>"$work/err"; then
  die "a failing grubby was reported as a kernel arg state"
fi
grep -q "grubby --info=ALL failed" "$work/err" || die "a failing grubby did not surface its error"
log "ok: a failing grubby surfaces instead of reading as missing"

printf 'ro quiet\n' > "$work/proc/cmdline"
[[ "$(GRUBBY_INFO="" kernel_arg_state "$BLACKLIST")" == missing ]] || die "empty grubby output is not missing"
log "ok: empty grubby output means missing"

: > "$work/proc/cmdline"
[[ "$(GRUBBY_INFO="args=\"$BLACKLIST\""$'\n' kernel_arg_state "$BLACKLIST")" == pending ]] || die "an empty cmdline is not pending"
log "ok: an empty cmdline has nothing active"

rm "$work/proc/cmdline"
if (kernel_cmdline_has pcie_aspm=off) 2>"$work/err"; then die "an unreadable cmdline answered instead of failing"; fi
grep -q "cannot read kernel command line file" "$work/err" || die "an unreadable cmdline did not surface its error"
log "ok: an unreadable cmdline fails instead of reading as false"

# --- ensure_kernel_arg ---

reset_boot_config() { # reset_boot_config <grubby args> <etc/kernel/cmdline>
  printf '%s\n' "$1" > "$work/grubby-args"
  printf '%s\n' "$2" > "$work/etc/kernel/cmdline"
  : > "$work/grubby.log"
}

reset_boot_config "ro $BLACKLIST" "ro $BLACKLIST"
ensure_kernel_arg "$BLACKLIST" 2>/dev/null
[[ ! -s "$work/grubby.log" ]] || die "an arg present in grubby and /etc/kernel/cmdline was updated again"
log "ok: ensure_kernel_arg skips an arg that is already configured"

reset_boot_config "ro" "ro"
ensure_kernel_arg "$BLACKLIST" 2>/dev/null
[[ "$(<"$work/grubby.log")" == "--update-kernel=ALL --args=$BLACKLIST" ]] || die "an absent arg was not added with grubby --update-kernel=ALL"
log "ok: ensure_kernel_arg adds an absent arg for all kernels"

reset_boot_config "ro $BLACKLIST" "ro"
ensure_kernel_arg "$BLACKLIST" 2>/dev/null
[[ -s "$work/grubby.log" ]] || die "an arg missing from /etc/kernel/cmdline was not added"
log "ok: ensure_kernel_arg repairs an arg that grubby has but /etc/kernel/cmdline lacks"

reset_boot_config "ro" "ro"
if (GRUBBY_UPDATE_STATUS=1 ensure_kernel_arg "$BLACKLIST") 2>"$work/err"; then die "a failing grubby update was not reported"; fi
grep -q "kernel arg not applied by grubby" "$work/err" || die "a failing grubby update did not surface its error"
log "ok: ensure_kernel_arg dies when grubby cannot apply the arg"

# --- nvidia_module_license / nvidia_module_problem ---

[[ "$(MODINFO_LICENSE=NVIDIA nvidia_module_license 7.0)" == NVIDIA ]] || die "the proprietary module's license was not read"
[[ -z "$(MODINFO_LICENSE=NVIDIA nvidia_module_problem 7.0)" ]] || die "a proprietary module was reported as a problem"
log "ok: a proprietary module (license NVIDIA) is fine"

[[ "$(MODINFO_LICENSE="Dual MIT/GPL" nvidia_module_license 7.0)" == "Dual MIT/GPL" ]] || die "the Open module's license was not read"
[[ "$(MODINFO_LICENSE="Dual MIT/GPL" nvidia_module_problem 7.0)" == *"license 'Dual MIT/GPL', expected NVIDIA"* ]] || die "the Open module was not reported"
log "ok: the Open module (Dual MIT/GPL) is a problem"

[[ -z "$(nvidia_module_license 7.0)" ]] || die "a missing module has a license"
[[ "$(nvidia_module_problem 7.0)" == "nvidia module missing or unreadable for 7.0 (license '')" ]] || die "a missing module was not reported"
log "ok: a missing module is reported as missing or unreadable"

# --- initramfs_has_nvidia ---

has_nvidia() { LSINITRD_OUT="$1" initramfs_has_nvidia 7.0; }

for listing in $'usr/lib/modules/7.0/extra/nvidia/nvidia.ko.xz' $'usr/lib/modules/7.0/extra/nvidia/nvidia.ko.zst' $'x/nvidia.ko'; do
  has_nvidia "$listing" || die "'$listing' was not recognised as containing nvidia"
done
log "ok: nvidia.ko in any compression counts as present"

for listing in $'x/nvidia-drm.ko.xz' $'x/nvidia_drm.ko' $'x/nvidia-drm.ko' $'' $'x/nvidia.kox'; do
  ! has_nvidia "$listing" || die "'$listing' was wrongly recognised as containing nvidia"
done
log "ok: nvidia-drm, nvidia_drm, an empty listing and a near-miss name do not count"

if (LSINITRD_STATUS=1 initramfs_has_nvidia 7.0) 2>"$work/err"; then die "a failing lsinitrd was not reported"; fi
grep -q "lsinitrd failed" "$work/err" || die "a failing lsinitrd did not surface its error"
log "ok: a failing lsinitrd surfaces instead of reading as no nvidia"

# --- initramfs_needs_nvidia_regen ---

img="$work/boot/initramfs-7.0.img"
module="$work/nvidia.ko"
conf="$work$DRACUT_NVIDIA_CONF"
touch -d '2026-01-02' "$module"
touch -d '2026-01-01' "$conf"
export MODINFO_LICENSE=NVIDIA MODINFO_PATH="$module"
HAS=$'x/nvidia.ko.xz'

rm -f "$img"
LSINITRD_OUT="$HAS" initramfs_needs_nvidia_regen 7.0 || die "a missing initramfs image does not need regeneration"
log "ok: a missing initramfs image needs regeneration"

touch -d '2026-01-03' "$img"
! LSINITRD_OUT="$HAS" initramfs_needs_nvidia_regen 7.0 || die "a current initramfs with nvidia needs regeneration"
log "ok: a current initramfs with nvidia is left alone"

LSINITRD_OUT=$'x/nvidia-drm.ko.xz' initramfs_needs_nvidia_regen 7.0 || die "an initramfs without nvidia does not need regeneration"
log "ok: an initramfs without nvidia needs regeneration"

touch -d '2026-01-04' "$module"
LSINITRD_OUT="$HAS" initramfs_needs_nvidia_regen 7.0 || die "an initramfs older than a rebuilt module does not need regeneration"
log "ok: an initramfs older than the module needs regeneration"

touch -d '2026-01-02' "$module"
touch -d '2026-01-05' "$conf"
LSINITRD_OUT="$HAS" initramfs_needs_nvidia_regen 7.0 || die "an initramfs older than the dracut config does not need regeneration"
log "ok: an initramfs older than the dracut config needs regeneration"

unset MODINFO_LICENSE
if (LSINITRD_OUT="$HAS" initramfs_needs_nvidia_regen 7.0) 2>"$work/err"; then die "a missing module was not reported"; fi
grep -q "nvidia module missing for 7.0" "$work/err" || die "a missing module did not surface its error"
log "ok: a missing nvidia module surfaces instead of reading as current"

# --- akmods_dropin_active ---

DROPIN="$(<"$ROOT/etc/systemd/system/akmods@.service.d/vekrona-dracut.conf")"
UNIT=$'# /usr/lib/systemd/system/akmods@.service\n[Service]\nExecStart=/usr/sbin/akmods --kernels %i\n'

akmods_unit() { SYSTEMCTL_OUT="$1" akmods_dropin_active 7.0; }

akmods_unit "$UNIT"$'\n'"$DROPIN" || die "the shipped drop-in was not recognised as active"
log "ok: the shipped akmods@ drop-in counts as active"

! akmods_unit "$UNIT" || die "a unit without the drop-in was reported active"
! akmods_unit "$UNIT"$'\n# ExecStartPost=/usr/bin/dracut -f --kver %i' || die "a commented-out dracut line was reported active"
! akmods_unit "$UNIT"$'\nExecStartPost=/usr/bin/dracut -f --kver %i --no-hostonly' || die "a near-miss dracut line was reported active"
log "ok: no drop-in, a commented line and a near-miss do not count"

if (SYSTEMCTL_STATUS=1 akmods_dropin_active 7.0) 2>"$work/err"; then die "a failing systemctl was not reported"; fi
grep -q "cannot read unit akmods@7.0.service" "$work/err" || die "a failing systemctl did not surface its error"
log "ok: an unreadable unit surfaces instead of reading as inactive"
