#!/usr/bin/env bash
# Runs the command of the akmods.service drop-in the way systemd does: as root, in an empty environment but the drop-in's own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

DROPIN="$ROOT/etc/systemd/system/akmods.service.d/vekrona-dracut.conf"
KVER=7.0.1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/boot" "$work/etc/dracut.conf.d" "$work/etc/modprobe.d"

write_fake "$work/bin/uname" <<'F'
#!/usr/bin/env bash
echo 7.0.1
F
write_fake "$work/bin/modinfo" <<'F'
#!/usr/bin/env bash
echo "$VEKRONA_SYSFS_ROOT/nvidia.ko"
F
write_fake "$work/bin/lsinitrd" <<'F'
#!/usr/bin/env bash
if [[ -e "$VEKRONA_SYSFS_ROOT/lsinitrd.forbidden" ]]; then echo "lsinitrd must not run" >&2; exit 1; fi
if [[ "${2-}" == -f ]]; then cat "$VEKRONA_SYSFS_ROOT/$3"; else echo "usr/lib/modules/7.0.1/extra/nvidia.ko.xz"; fi
F
write_fake "$work/bin/dracut" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$VEKRONA_SYSFS_ROOT/dracut.log"
F
echo options >"$work/etc/modprobe.d/vekrona-nvidia.conf"
touch -d '2 days ago' "$work/nvidia.ko" "$work/etc/modprobe.d/vekrona-nvidia.conf"
touch "$work/etc/dracut.conf.d/99-nvidia-dracut.conf"
touch -d '1 day ago' "$work/etc/dracut.conf.d/99-nvidia-dracut.conf"

command_line="$(sed -n 's/^ExecStartPost=//p' "$DROPIN")"
[[ "$command_line" == /usr/local/lib/vekrona/libexec/* ]] || die "the drop-in must run the root-owned copy of the script, got: $command_line"
script="$ROOT/${command_line#/usr/local/lib/vekrona/}"
mapfile -t unit_environment < <(sed -n 's/^Environment=//p' "$DROPIN")

# A system unit starts with no HOME, no user and the unit's own Environment=; the fakes stand in for the hardware.
run_as_systemd() {
  rc=0
  sudo env -i "${unit_environment[@]}" PATH="$work/bin:/usr/bin:/usr/sbin" VEKRONA_SYSFS_ROOT="$work" VEKRONA_KERNEL_LOCK="$work/kernel.lock" "$script" >"$work/out" 2>&1 || rc=$?
}

# The boot is the common case and decides on file times alone: reading the initramfs costs seconds of disk and CPU.
touch "$work/lsinitrd.forbidden"
touch "$work/boot/initramfs-$KVER.img"
run_as_systemd
[[ "$rc" == 0 ]] || die "the drop-in's command failed on a current initramfs (it must not read the image): $(cat "$work/out")"
[[ ! -e "$work/dracut.log" ]] || die "a current initramfs with nvidia was rebuilt: $(cat "$work/dracut.log")"
log "ok: the drop-in's command runs in a system unit's environment and leaves a current initramfs alone without reading it"

rm "$work/lsinitrd.forbidden"
for input in nvidia.ko etc/dracut.conf.d/99-nvidia-dracut.conf etc/modprobe.d/vekrona-nvidia.conf; do
  touch -d '1 day ago' "$work/boot/initramfs-$KVER.img"
  touch -d '2 days ago' "$work/nvidia.ko" "$work/etc/dracut.conf.d/99-nvidia-dracut.conf" "$work/etc/modprobe.d/vekrona-nvidia.conf"
  touch "$work/$input"
  rm -f "$work/dracut.log"
  run_as_systemd
  [[ "$rc" == 0 && "$(<"$work/dracut.log")" == "-f --kver $KVER" ]] || die "an initramfs older than $input was not rebuilt: exit $rc: $(cat "$work/out")"
done
log "ok: an initramfs older than the nvidia module, the dracut config or the modprobe options is rebuilt"
rm -f "$work/dracut.log"

rm "$work/boot/initramfs-$KVER.img"
run_as_systemd
[[ "$rc" == 0 && "$(<"$work/dracut.log")" == "-f --kver $KVER" ]] || die "a missing initramfs was not rebuilt: exit $rc: $(cat "$work/out")"
log "ok: a missing initramfs is rebuilt for the running kernel"
