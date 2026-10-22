#!/usr/bin/env bash
# A fake machine for the update pipeline tests (source it after tests/lib.sh). make_world DIR puts command stubs first
# on PATH and points every state path of the scripts into DIR. Tests set the machine up through the files named below,
# and read what the scripts did from $FAKE_LOG, one line per call.
#
#   sessions/ID          logind session ID, "Key=Value" lines (add_session)
#   inhibitors           what `systemd-inhibit --list` prints (systemd-inhibit's table rows)
#   units/UNIT.active    exists while the unit is active
#   dnf.json, dnf.rc     what `dnf5 check-upgrade --json` prints, and the exit status of check-upgrade: 0 nothing,
#                        100 updates (plain output only; --json exits 0 then, as dnf5 does), anything else a failure
#   upgrade.rc           exit status of `dnf5 upgrade`
#   assumeno.out, .rc    what `dnf5 upgrade --assumeno` prints and its exit status (default: a transaction dnf declined, 1)
#   notify.fails         exists while notify-send fails
#   proton.fails         exists while `vekrona-proton stage` fails (its feed cannot be read)
#   flatpak.tsv, installed.tsv   what flatpak remote-ls and rpm -qa print
#   offline.status       what `dnf5 offline status` prints; `dnf5 upgrade --offline` stores a transaction unless
#                        offline.empty exists (dnf skipped everything check-upgrade listed)
#   answer               what vekrona-update-ask prints
#   packages, kernels    installed package names (rpm -q), and installed kernel-core versions, one per line
#   modules/KVER         exists while the nvidia module is built for that kernel; modules/KVER.license holds its
#                        license when that is not NVIDIA (the open module)
#   default-kernel       the version `grubby --default-kernel` prints; `grubby --set-default` writes it
#   saved-entry          the saved_entry `grub2-editenv list` prints (sysroot/boot/loader/entries/ID.conf are the entries)
#   akmods-failed/KVER   exists while akmods has a failed build log for that kernel and ignores it unless --force is given
#   sysroot/boot         initramfs-KVER.img: the lines lsinitrd lists (add_kernel writes them)
#   akmods.rc, dracut.rc exit status of `akmods` (which then builds nothing and leaves a failed log) and of `dracut` (default 0)
#   akmods.builds-nothing  exists while akmods exits 0 without building a module
#   dracut.nonvidia      exists while dracut leaves nvidia out of the image although the module exists
#   initramfs.stale-options  exists while the images carry an older vekrona-nvidia.conf than the one on disk
#
# The scripts insist on root, which a user namespace that maps the caller to uid 0 gives them (run_as_root).

unshare -r true || die "cannot create a user namespace to stand in for root"

make_world() {
  local w="$1"
  mkdir -p "$w/bin" "$w/sessions" "$w/units" "$w/state" "$w/repos"
  : >"$w/log"
  : >"$w/inhibitors"
  echo '{}' >"$w/dnf.json"
  echo 0 >"$w/dnf.rc"
  echo 0 >"$w/upgrade.rc"
  printf 'Repositories loaded.\nTransaction Summary:\n Upgrading: 1 package\n\nOperation aborted by the user.\n' >"$w/assumeno.out"
  echo 1 >"$w/assumeno.rc"
  : >"$w/flatpak.tsv"
  : >"$w/installed.tsv"
  : >"$w/packages"
  mkdir -p "$w/modules" "$w/akmods-failed" "$w/sysroot/boot/loader/entries" "$w/sysroot/etc/dracut.conf.d" "$w/sysroot/etc/modprobe.d"
  echo 7.0.0-100.fc44.x86_64 >"$w/kernels"
  touch "$w/sysroot/boot/vmlinuz-7.0.0-100.fc44.x86_64"
  echo 7.0.0-100.fc44.x86_64 >"$w/default-kernel"
  echo 0 >"$w/akmods.rc"
  echo 0 >"$w/dracut.rc"
  echo 'options nvidia NVreg_UseKernelSuspendNotifiers=0' >"$w/sysroot/etc/modprobe.d/vekrona-nvidia.conf"
  touch -d 2026-01-01 "$w/sysroot/etc/modprobe.d/vekrona-nvidia.conf" "$w/sysroot/etc/dracut.conf.d/99-nvidia-dracut.conf"
  echo "No offline transaction is stored." >"$w/offline.status"
  echo timeout >"$w/answer"
  cat >"$w/bin/loginctl" <<'F'
#!/usr/bin/env bash
case "$1" in
  list-sessions) for f in "$FAKE_WORLD"/sessions/*; do [[ -e "$f" ]] && echo "${f##*/} 1000 someone seat0 100 user tty1 no -"; done; exit 0 ;;
  show-session)
    id="$2"; shift 2
    while [[ $# -gt 0 ]]; do [[ "$1" == -p ]] && grep "^$2=" "$FAKE_WORLD/sessions/$id"; shift 2; done
    ;;
esac
F
  cat >"$w/bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE_WORLD/log"
case "$1" in
  is-active) if [[ -e "$FAKE_WORLD/units/$2.active" ]]; then echo active; else echo inactive; exit 3; fi ;;
  start) touch "$FAKE_WORLD/units/$2.active" ;;
  stop) rm -f "$FAKE_WORLD/units/$2.active" ;;
esac
F
  cat >"$w/bin/systemd-inhibit" <<'F'
#!/usr/bin/env bash
cat "$FAKE_WORLD/inhibitors"
F
  cat >"$w/bin/runuser" <<'F'
#!/usr/bin/env bash
# runuser -u NAME -- env VAR=VALUE... COMMAND ARGS...
echo "runuser $*" >>"$FAKE_WORLD/log"
shift 3
[[ "$1" == env ]] && shift
while [[ "$1" == *=* ]]; do shift; done
case "${1##*/}" in
  vekrona-update-ask) cat "$FAKE_WORLD/answer" ;;
  notify-send) [[ ! -e "$FAKE_WORLD/notify.fails" ]] || exit 1 ;;
  *) echo "runuser stub: unexpected command $1" >&2; exit 99 ;;
esac
F
  cat >"$w/bin/dnf5" <<'F'
#!/usr/bin/env bash
echo "dnf5 $*" >>"$FAKE_WORLD/log"
case "$1" in
  check-upgrade) rc="$(<"$FAKE_WORLD/dnf.rc")"
                 if [[ " $* " == *" --json "* ]]; then cat "$FAKE_WORLD/dnf.json"; [[ "$rc" -ne 100 ]] || rc=0; fi
                 exit "$rc" ;;
  upgrade) if flock --nonblock "$VEKRONA_UPDATE_LOCK" true; then echo "dnf5 ran without the update lock" >>"$FAKE_WORLD/log"; fi
           if [[ " $* " == *" --assumeno "* ]]; then cat "$FAKE_WORLD/assumeno.out"; exit "$(<"$FAKE_WORLD/assumeno.rc")"; fi
           if [[ " $* " == *" --offline "* && ! -e "$FAKE_WORLD/offline.empty" ]]; then
             echo "An offline transaction was initiated on today." >"$FAKE_WORLD/offline.status"
           fi
           exit "$(<"$FAKE_WORLD/upgrade.rc")" ;;
  offline) case "$2" in status) cat "$FAKE_WORLD/offline.status" ;; log) echo "offline log line" ;; esac ;;
esac
F
  cat >"$w/bin/rpm" <<'F'
#!/usr/bin/env bash
if [[ "$1" == -q ]]; then
  case "$2" in
    kernel-core) cat "$FAKE_WORLD/kernels" ;;
    # Like the real rpm: an installed package is named on stdout, a missing one is reported there too, and exits 1.
    *) if grep -qxF -- "$2" "$FAKE_WORLD/packages"; then echo "$2-1.0-1.fc44.x86_64"; else echo "package $2 is not installed"; exit 1; fi ;;
  esac
  exit
fi
cat "$FAKE_WORLD/installed.tsv"
F
  cat >"$w/bin/modinfo" <<'F'
#!/usr/bin/env bash
# modinfo -k KVER (-F license|-F version|-n) nvidia
[[ -e "$FAKE_WORLD/modules/$2" ]] || exit 1
case "$3" in
  -F) case "$4" in
        license) if [[ -e "$FAKE_WORLD/modules/$2.license" ]]; then cat "$FAKE_WORLD/modules/$2.license"; else echo NVIDIA; fi ;;
        version) echo 615.71.09 ;;
      esac ;;
  -n) echo "$FAKE_WORLD/modules/$2" ;;
esac
F
  cat >"$w/bin/akmods" <<'F'
#!/usr/bin/env bash
# akmods [--rebuild] [--force] --kernels KVER: plain akmods builds and installs the kmod (dnf install); --rebuild
# reinstalls it, which dnf5 reports as "Nothing to do" and exit status 0 for a kmod that was never installed. A kernel
# with a failed build log is ignored (exit status 0, nothing built) unless --force is given; a failed build leaves one.
echo "akmods $*" >>"$FAKE_WORLD/log"
rebuild="" force=""
while [[ "$1" != --kernels ]]; do
  case "$1" in --rebuild) rebuild=1 ;; --force) force=1 ;; *) echo "akmods stub: unexpected argument $1" >&2; exit 99 ;; esac
  shift
done
kver="$2"
[[ -n "$force" || ! -e "$FAKE_WORLD/akmods-failed/$kver" ]] || exit 0
rc="$(<"$FAKE_WORLD/akmods.rc")"
[[ "$rc" -eq 0 ]] || { touch "$FAKE_WORLD/akmods-failed/$kver"; exit "$rc"; }
[[ ! -e "$FAKE_WORLD/akmods.builds-nothing" ]] || exit 0
if [[ -n "$rebuild" ]] && ! grep -qxF "kmod-nvidia-$kver" "$FAKE_WORLD/packages"; then exit 0; fi
rm -f "$FAKE_WORLD/akmods-failed/$kver" "$FAKE_WORLD/modules/$kver.license"
touch "$FAKE_WORLD/modules/$kver"
grep -qxF "kmod-nvidia-$kver" "$FAKE_WORLD/packages" || echo "kmod-nvidia-$kver" >>"$FAKE_WORLD/packages"
F
  cat >"$w/bin/grubby" <<'F'
#!/usr/bin/env bash
echo "grubby $*" >>"$FAKE_WORLD/log"
case "$1" in
  --default-kernel) echo "/boot/boot/vmlinuz-$(<"$FAKE_WORLD/default-kernel")" ;;
  --set-default)
    kver="${2#/boot/vmlinuz-}"
    [[ -e "$FAKE_WORLD/sysroot/boot/vmlinuz-$kver" ]] || { echo "The param $2 is not a valid kernel" >&2; exit 1; }
    echo "$kver" >"$FAKE_WORLD/default-kernel" ;;
  *) echo "grubby stub: unexpected arguments $*" >&2; exit 99 ;;
esac
F
  cat >"$w/bin/grub2-editenv" <<'F'
#!/usr/bin/env bash
[[ "$1" == list ]] || { echo "grub2-editenv stub: unexpected arguments $*" >&2; exit 99; }
echo "# GRUB Environment Block"
[[ ! -e "$FAKE_WORLD/saved-entry" ]] || echo "saved_entry=$(<"$FAKE_WORLD/saved-entry")"
F
  cat >"$w/bin/dracut" <<'F'
#!/usr/bin/env bash
# dracut -f --kver KVER
echo "dracut $*" >>"$FAKE_WORLD/log"
rc="$(<"$FAKE_WORLD/dracut.rc")"
[[ "$rc" -eq 0 ]] || exit "$rc"
echo init >"$FAKE_WORLD/sysroot/boot/initramfs-$3.img"
if [[ -e "$FAKE_WORLD/modules/$3" && ! -e "$FAKE_WORLD/dracut.nonvidia" ]]; then
  echo "usr/lib/modules/$3/extra/nvidia/nvidia.ko.xz" >>"$FAKE_WORLD/sysroot/boot/initramfs-$3.img"
fi
F
  cat >"$w/bin/lsinitrd" <<'F'
#!/usr/bin/env bash
# lsinitrd IMAGE [-f FILE]: dracut bakes the nvidia modprobe options in
echo "lsinitrd $*" >>"$FAKE_WORLD/log"
if [[ "${2:-}" == -f ]]; then
  if [[ -e "$FAKE_WORLD/initramfs.stale-options" ]]; then echo "options nvidia NVreg_UseKernelSuspendNotifiers=1"
  else cat "$FAKE_WORLD/sysroot/etc/modprobe.d/vekrona-nvidia.conf"; fi
else cat "$1"; fi
F
  cat >"$w/bin/flatpak" <<'F'
#!/usr/bin/env bash
echo "flatpak $*" >>"$FAKE_WORLD/log"
[[ "$1" != remote-ls ]] || cat "$FAKE_WORLD/flatpak.tsv"
F
  cat >"$w/bin/snapper" <<'F'
#!/usr/bin/env bash
echo "snapper $*" >>"$FAKE_WORLD/log"
if [[ " $* " == *" --pre-number "* ]]; then echo 11; else echo 10; fi
F
  cat >"$w/bin/vekrona-proton" <<'F'
#!/usr/bin/env bash
echo "vekrona-proton $*" >>"$FAKE_WORLD/log"
[[ ! -e "$FAKE_WORLD/proton.fails" ]] || { echo "[vekrona] FAIL: cannot read Proton feed" >&2; exit 1; }
F
  chmod +x "$w/bin/"*
  export PATH="$w/bin:$PATH" FAKE_WORLD="$w" FAKE_LOG="$w/log" \
    VEKRONA_STATE_DIR="$w/state" VEKRONA_UPDATE_LOCK="$w/lock" VEKRONA_KERNEL_LOCK="$w/kernel.lock" VEKRONA_PROTON="$w/bin/vekrona-proton" \
    VEKRONA_YUM_REPOS_DIR="$w/repos" VEKRONA_SYSFS_ROOT="$w/sysroot" AKMODS_LOCK="$w/akmods.lock" VEKRONA_SYSTEMD_UNIT_DIR="$w/units-installed"
}

# add_session ID KEY=VALUE...: a logind session that is, unless said otherwise, an awake Wayland user's.
add_session() {
  local id="$1"
  shift
  printf '%s\n' Type=wayland Active=yes LockedHint=no IdleHint=no Name=someone User=1000 "$@" >"$FAKE_WORLD/sessions/$id"
}

# add_nvidia_machine KVER...: akmod-nvidia is installed with these kernels, oldest first, none with a module or an image.
# The oldest is the GRUB default, as it stays while a newer kernel is not ready (UPDATEDEFAULT=no).
add_nvidia_machine() {
  local kver
  echo akmod-nvidia >"$FAKE_WORLD/packages"
  printf '%s\n' "$@" >"$FAKE_WORLD/kernels"
  for kver in "$@"; do touch "$FAKE_WORLD/sysroot/boot/vmlinuz-$kver"; done
  echo "$1" >"$FAKE_WORLD/default-kernel"
}

# kernel_state KVER KEY...: module (the proprietary nvidia module is built and its kmod installed), open-module (the same
# with the open module), failed-build (akmods has a failed build log for the kernel), initramfs (the image lacks nvidia),
# nvidia-initramfs (the image carries nvidia). Module and image are dated so that the image is current.
kernel_state() {
  local kver="$1" key image="$FAKE_WORLD/sysroot/boot/initramfs-$1.img"
  shift
  rm -f "$FAKE_WORLD/modules/$kver" "$FAKE_WORLD/modules/$kver.license" "$FAKE_WORLD/akmods-failed/$kver" "$image"
  for key in "$@"; do
    case "$key" in
      module | open-module)
        touch -d 2026-01-02 "$FAKE_WORLD/modules/$kver"
        echo "kmod-nvidia-$kver" >>"$FAKE_WORLD/packages"
        [[ "$key" != open-module ]] || echo "Dual MIT/GPL" >"$FAKE_WORLD/modules/$kver.license" ;;
      failed-build) touch "$FAKE_WORLD/akmods-failed/$kver" ;;
      initramfs) echo init >"$image" ;;
      nvidia-initramfs) printf 'init\nusr/lib/modules/%s/extra/nvidia/nvidia.ko.xz\n' "$kver" >"$image" ;;
      *) die "kernel_state: unknown key $key" ;;
    esac
  done
  [[ ! -e "$image" ]] || touch -d 2026-01-03 "$image"
}

run_as_root() { unshare -r "$@"; }
log_lines() { grep -c -- "$1" "$FAKE_LOG" || true; }
