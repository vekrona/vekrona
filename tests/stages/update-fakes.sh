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
#   notify.fails         exists while notify-send fails
#   flatpak.tsv, mise.json, installed.tsv   what flatpak remote-ls, mise outdated and rpm -qa print
#   offline.status       what `dnf5 offline status` prints; `dnf5 upgrade --offline` stores a transaction unless
#                        offline.empty exists (dnf skipped everything check-upgrade listed)
#   answer               what vekrona-update-ask prints
#   packages, kernels    installed package names (rpm -q), and installed kernel-core versions, one per line
#   modules/KVER         exists while the nvidia module is built for that kernel
#   sysroot/boot         initramfs-KVER.img: the lines lsinitrd lists (add_kernel writes them)
#   akmods.rc, dracut.rc exit status of `akmods --rebuild` (which then builds nothing) and of `dracut` (default 0)
#   dracut.nonvidia      exists while dracut leaves nvidia out of the image although the module exists
#   mise.warns           mise upgrade prints a version lookup warning and exits 0, as it does when DNS fails
#
# The scripts insist on root, which a user namespace that maps the caller to uid 0 gives them (run_as_root).

unshare -r true || die "cannot create a user namespace to stand in for root"

make_world() {
  local w="$1"
  mkdir -p "$w/bin" "$w/sessions" "$w/units" "$w/state" "$w/repos" "$w/mise"
  : >"$w/log"
  : >"$w/inhibitors"
  echo '{}' >"$w/dnf.json"
  echo 0 >"$w/dnf.rc"
  echo 0 >"$w/upgrade.rc"
  : >"$w/flatpak.tsv"
  echo '{}' >"$w/mise.json"
  : >"$w/installed.tsv"
  : >"$w/packages"
  : >"$w/kernels"
  mkdir -p "$w/modules" "$w/sysroot/boot" "$w/sysroot/etc/dracut.conf.d" "$w/sysroot/etc/modprobe.d"
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
    *) grep -qxF -- "$2" "$FAKE_WORLD/packages" ;;
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
  -F) case "$4" in license) echo NVIDIA ;; version) echo 615.71.09 ;; esac ;;
  -n) echo "$FAKE_WORLD/modules/$2" ;;
esac
F
  cat >"$w/bin/akmods" <<'F'
#!/usr/bin/env bash
# akmods --rebuild --kernels KVER
echo "akmods $*" >>"$FAKE_WORLD/log"
rc="$(<"$FAKE_WORLD/akmods.rc")"
[[ "$rc" -ne 0 ]] || touch "$FAKE_WORLD/modules/$3"
exit "$rc"
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
# lsinitrd IMAGE [-f FILE]: dracut always bakes the nvidia modprobe options in
if [[ "${2:-}" == -f ]]; then cat "$FAKE_WORLD/sysroot/etc/modprobe.d/vekrona-nvidia.conf"; else cat "$1"; fi
F
  cat >"$w/bin/flatpak" <<'F'
#!/usr/bin/env bash
echo "flatpak $*" >>"$FAKE_WORLD/log"
[[ "$1" != remote-ls ]] || cat "$FAKE_WORLD/flatpak.tsv"
F
  cat >"$w/bin/mise" <<'F'
#!/usr/bin/env bash
echo "mise $*" >>"$FAKE_WORLD/log"
if [[ -e "$FAKE_WORLD/mise.warns" && "$1" == upgrade ]]; then
  echo "mise WARN  Error getting latest version for cursor-agent: dns error: Name or service not known" >&2
fi
[[ "$1" != outdated ]] || cat "$FAKE_WORLD/mise.json"
F
  cat >"$w/bin/snapper" <<'F'
#!/usr/bin/env bash
echo "snapper $*" >>"$FAKE_WORLD/log"
if [[ " $* " == *" --pre-number "* ]]; then echo 11; else echo 10; fi
F
  cat >"$w/bin/vekrona-proton" <<'F'
#!/usr/bin/env bash
echo "vekrona-proton $*" >>"$FAKE_WORLD/log"
F
  chmod +x "$w/bin/"*
  export PATH="$w/bin:$PATH" FAKE_WORLD="$w" FAKE_LOG="$w/log" \
    VEKRONA_STATE_DIR="$w/state" VEKRONA_UPDATE_LOCK="$w/lock" VEKRONA_PROTON="$w/bin/vekrona-proton" \
    VEKRONA_YUM_REPOS_DIR="$w/repos" VEKRONA_SYSFS_ROOT="$w/sysroot" AKMODS_LOCK="$w/akmods.lock" VEKRONA_SYSTEMD_UNIT_DIR="$w/units-installed" MISE_SYSTEM_DATA_DIR="$w/mise"
}

# add_session ID KEY=VALUE...: a logind session that is, unless said otherwise, an awake Wayland user's.
add_session() {
  local id="$1"
  shift
  printf '%s\n' Type=wayland Active=yes LockedHint=no IdleHint=no Name=someone User=1000 "$@" >"$FAKE_WORLD/sessions/$id"
}

# add_nvidia_machine KVER...: akmod-nvidia is installed with these kernels, oldest first, none with a module or an image.
add_nvidia_machine() {
  echo akmod-nvidia >"$FAKE_WORLD/packages"
  printf '%s\n' "$@" >"$FAKE_WORLD/kernels"
}

# kernel_state KVER KEY...: module (the nvidia module is built), initramfs (the image lacks nvidia), nvidia-initramfs (the
# image carries nvidia). Module and image are dated so that the image is current.
kernel_state() {
  local kver="$1" key image="$FAKE_WORLD/sysroot/boot/initramfs-$1.img"
  shift
  rm -f "$FAKE_WORLD/modules/$kver" "$image"
  for key in "$@"; do
    case "$key" in
      module) touch -d 2026-01-02 "$FAKE_WORLD/modules/$kver" ;;
      initramfs) echo init >"$image" ;;
      nvidia-initramfs) printf 'init\nusr/lib/modules/%s/extra/nvidia/nvidia.ko.xz\n' "$kver" >"$image" ;;
      *) die "kernel_state: unknown key $key" ;;
    esac
  done
  [[ ! -e "$image" ]] || touch -d 2026-01-03 "$image"
}

run_as_root() { unshare -r "$@"; }
log_lines() { grep -c -- "$1" "$FAKE_LOG" || true; }
