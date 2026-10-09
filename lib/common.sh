#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

VEKRONA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VEKRONA_ROOT
VEKRONA_USER="$(id -un)"
# Where earlier installs lived (a plain checkout, then install.sh's own clone); links into them are legacy and
# get repointed or pruned, unless that tree is the one running.
VEKRONA_LEGACY_ROOTS=("$HOME/vekrona" "$HOME/.local/share/vekrona")

log()  { printf '\033[1;34m[vekrona]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[vekrona] WARN:\033[0m %s\n' "$*" >&2; }

VEKRONA_ERROR_REPORTER="${VEKRONA_ERROR_REPORTER:-$VEKRONA_ROOT/bin/vekrona-error}"

report_error_for_die() {
  timeout 5 "$VEKRONA_ERROR_REPORTER" report --title "$1" --source vekrona >/dev/null 2>&1
}

die()  {
  printf '\033[1;31m[vekrona] FAIL:\033[0m %s\n' "$*" >&2
  report_error_for_die "$*" || warn "failed to report this error to vekrona-error"
  exit 1
}

root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# Single chokepoint for acquiring sudo credentials. Without a terminal an interactive sudo cannot take the FIDO tap or
# PIN and only logs a pam_unix "conversation failed" record, so that case dies before sudo is asked anything.
# sudo prompts on /dev/tty, so the test is for a controlling terminal, not for a terminal on stdin.
sudo_refresh() {
  [[ $EUID -eq 0 ]] && return 0
  sudo -n true 2>/dev/null && return 0
  { : </dev/tty; } 2>/dev/null || die "sudo needs a terminal for the FIDO tap/PIN: run $(basename "$0") from a terminal"
  sudo -v || die "sudo credentials required"
}

# Prints the IPC socket of the user's sway session, or nothing when none runs. A terminal inside sway has SWAYSOCK;
# a TTY or SSH login does not, so look for the session's socket where sway creates it (sway-ipc.UID.PID.sock).
# A crashed sway leaves its socket behind, so only sockets whose sway PID is alive count; for the same reason a
# SWAYSOCK inherited by a tmux that outlived its sway is used only if sway answers on it.
sway_socket() {
  local socket pid live=()
  if [[ -n "${SWAYSOCK:-}" ]] && swaymsg -s "$SWAYSOCK" -t get_version >/dev/null 2>&1; then
    printf '%s\n' "$SWAYSOCK"
    return 0
  fi
  for socket in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/sway-ipc.*.sock; do
    [[ -S "$socket" ]] || continue
    pid="${socket%.sock}"
    pid="${pid##*.}"
    [[ -d "/proc/$pid" ]] && live+=("$socket")
  done
  ((${#live[@]} <= 1)) || die "more than one running sway session, cannot tell which to reload: ${live[*]}"
  ((${#live[@]} == 0)) || printf '%s\n' "${live[0]}"
}

# The sway config is symlinked into the checkout, so a running session keeps the old one until it is told to reload.
reload_running_sway() {
  local socket
  socket="$(sway_socket)"
  if [[ -z "$socket" ]]; then
    log "no running sway session, skipping the sway reload"
    return 0
  fi
  log "reloading the running sway session"
  swaymsg -s "$socket" reload >/dev/null || die "swaymsg reload failed (socket $socket)"
}

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done
}

pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }

ensure_pkg() {
  local missing=()
  local p
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  [[ ${#missing[@]} -eq 0 ]] && { log "packages present: $*"; return 0; }
  log "installing: ${missing[*]}"
  root dnf install -y "${missing[@]}"
  for p in "${missing[@]}"; do pkg_installed "$p" || die "package did not install: $p"; done
}

ensure_pkg_from_repo() {
  local repo="$1"; shift
  local p
  for p in "$@"; do
    local from
    from="$(dnf repoquery --installed --qf '%{from_repo}\n' "$p" 2>/dev/null || true)"
    if [[ "$from" == "$repo" ]]; then log "$p already from $repo"; continue; fi
    log "installing $p from $repo"
    root dnf install -y --from-repo="$repo" "$p"
    from="$(dnf repoquery --installed --qf '%{from_repo}\n' "$p" 2>/dev/null)"
    [[ "$from" == "$repo" ]] || die "$p installed from $from, expected $repo"
  done
}

# Removes installed packages through a --assumeno transaction first, which dies when it would take a desktop package along.
ensure_pkg_absent() {
  local installed=() pkg out protected rc=0
  for pkg in "$@"; do pkg_installed "$pkg" && installed+=("$pkg"); done
  if [[ ${#installed[@]} -eq 0 ]]; then log "packages absent: $*"; return 0; fi
  protected="$(vekrona_desktop_pkgs | paste -sd,)"
  out="$(root dnf remove --assumeno --setopt=protected_packages="$protected" "${installed[@]}" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  [[ "$out" != *"protected packages"* ]] || die "dnf remove ${installed[*]} would remove protected packages"
  [[ $rc -eq 1 && "$out" == *"Operation aborted"* ]] || die "dnf remove ${installed[*]} --assumeno failed unexpectedly (exit $rc)"
  log "removing: ${installed[*]}"
  root dnf remove -y --setopt=protected_packages="$protected" "${installed[@]}"
  for pkg in "${installed[@]}"; do
    ! pkg_installed "$pkg" || die "package still installed: $pkg"
  done
}

ensure_pkg_swapped() {
  local from="$1" to="$2"
  if pkg_installed "$to" && ! pkg_installed "$from"; then log "already swapped: $from -> $to"; return 0; fi
  if ! pkg_installed "$from"; then
    log "installing $to, replacing whatever of $from's libraries conflicts with it"
    root dnf install -y --allowerasing "$to"
    pkg_installed "$to" || die "package did not install: $to"
    return 0
  fi
  log "swapping: $from -> $to"
  root dnf swap -y "$from" "$to" --allowerasing
  { pkg_installed "$to" && ! pkg_installed "$from"; } || die "swap did not complete: $from -> $to"
}

mark_user_installed() {
  local installed=()
  local p
  for p in "$@"; do pkg_installed "$p" && installed+=("$p"); done
  [[ ${#installed[@]} -eq 0 ]] && { log "no installed packages to mark user among: $*"; return 0; }
  root dnf mark -y user "${installed[@]}"
}

repo_enabled() {
  local ids
  ids="$(dnf repolist --enabled 2>/dev/null | awk '{print $1}')" || die "dnf repolist failed"
  grep -qx -- "$1" <<<"$ids"
}

ensure_repo_enabled() {
  local r
  for r in "$@"; do
    repo_enabled "$r" && { log "repo enabled: $r"; continue; }
    log "enabling repo: $r"
    root dnf config-manager setopt "$r.enabled=1"
    repo_enabled "$r" || die "repo not enabled: $r"
  done
}

ensure_copr() {
  local c
  for c in "$@"; do
    local id
    id="$(copr_id "$c")"
    repo_enabled "$id" && { log "copr enabled: $c"; continue; }
    log "enabling copr: $c"
    root dnf copr enable -y "$c"
    repo_enabled "$id" || die "copr not enabled: $c"
  done
}

ensure_copr_absent() {
  local c
  for c in "$@"; do
    local id
    id="$(copr_id "$c")"
    repo_enabled "$id" || continue
    log "removing copr: $c"
    root dnf copr remove -y "$c"
    repo_enabled "$id" && die "copr still enabled: $c"
  done
}

ensure_root_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  [[ -f "$src" ]] || die "source missing: $src"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then log "up to date: $dst"; return 0; fi
  log "installing: $dst"
  root install -D -m "$mode" "$src" "$dst"
  cmp -s "$src" "$dst" || die "content mismatch after install: $dst"
}

# grep -q on a file: 0 match, 1 no match; any other grep status (unreadable file, a directory) is an error, not "absent".
file_grep_q() {
  local status=0
  grep -q "$@" || status=$?
  [[ $status -le 1 ]] || die "grep -q $* failed with exit status $status"
  return "$status"
}

ensure_line() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && file_grep_q -xF -- "$line" "$file"; then log "line present in $file: $line"; return 0; fi
  log "appending to $file: $line"
  printf '%s\n' "$line" | root tee -a "$file" >/dev/null
  file_grep_q -xF -- "$line" "$file" || die "line not written to $file"
}

user_gsettings() {
  local bus
  bus="/run/user/$(id -u)/bus"
  if [[ -S "$bus" ]]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" gsettings "$@"
  else
    dbus-run-session -- gsettings "$@"
  fi
}

ensure_gsettings() {
  local schema="$1" key="$2" value="$3" current
  local want="'$value'"
  current="$(user_gsettings get "$schema" "$key")" || die "gsettings get failed: $schema $key"
  [[ "$current" == "$want" ]] && { log "gsettings already set: $schema $key"; return 0; }
  log "setting gsettings: $schema $key = $value"
  user_gsettings set "$schema" "$key" "$value" || die "gsettings set failed: $schema $key"
  current="$(user_gsettings get "$schema" "$key")"
  [[ "$current" == "$want" ]] || die "gsettings not applied: $schema $key"
}

# Prints the first symlinked directory between $HOME and DST's parent (nothing when there is none).
# Such a directory is managed by someone else (e.g. ~/.config/ghostty -> ~/.dotfiles/config/ghostty).
# $HOME itself and anything above it may be symlinks legitimately, so only components below it count.
symlinked_parent_below_home() {
  local dst="$1" home_lex dir
  home_lex="$(realpath -sm "$HOME")"
  dir="$(realpath -sm "$(dirname "$dst")")"
  while [[ "$dir" == "$home_lex"/* ]]; do
    if [[ -L "$dir" ]]; then printf '%s' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 0
}

ensure_symlink() {
  local src="$1" dst="$2" managed
  [[ -e "$src" ]] || die "symlink source missing: $src"
  managed="$(symlinked_parent_below_home "$dst")"
  if [[ -n "$managed" ]]; then
    warn "skipping $dst: $managed is a symlink to $(readlink -f "$managed"), managed elsewhere"
    return 0
  fi
  if [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]]; then log "linked: $dst"; return 0; fi
  if [[ -L "$dst" ]]; then
    warn "replacing symlink $dst, previous target: $(readlink "$dst")"
  elif [[ -e "$dst" ]]; then
    local backup="$dst.pre-vekrona"
    [[ -e "$backup" ]] && die "backup already exists, resolve manually: $backup"
    warn "backing up existing $dst to $backup"
    mv "$dst" "$backup"
  fi
  mkdir -p "$(dirname "$dst")"
  ln -sfn "$src" "$dst"
  [[ "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]] || die "symlink failed: $dst"
  log "linked: $dst -> $src"
}

# Vekrona is always installed from a git checkout (docs/install.md clones it; the ISO payload is a clone), and the
# checkout's .gitignore is what separates the files it ships from build junk such as bin/__pycache__.
require_git_checkout() {
  git -C "$VEKRONA_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$VEKRONA_ROOT is not a git checkout (or git is missing): vekrona links only the files git tracks or does not ignore"
}

# Succeeds when git ignores the path inside $VEKRONA_ROOT. Tracked files are never ignored.
is_ignored_in_checkout() {
  local rc=0
  git -C "$VEKRONA_ROOT" check-ignore -q -- "$1" || rc=$?
  case $rc in
    0) return 0 ;;
    1) return 1 ;;
    *) die "git check-ignore failed (exit $rc) for $1 in $VEKRONA_ROOT" ;;
  esac
}

# Links every regular file under srcdir that git tracks or that is untracked but not ignored.
ensure_symlink_tree() {
  local srcdir="$1" dstdir="$2"
  [[ -d "$srcdir" ]] || die "directory missing: $srcdir"
  require_git_checkout
  local rel
  while IFS= read -r -d '' rel; do
    # --cached still lists tracked files deleted from the working tree, and tracked symlinks.
    [[ -f "$srcdir/$rel" && ! -L "$srcdir/$rel" ]] || continue
    ensure_symlink "$srcdir/$rel" "$dstdir/$rel"
  done < <(git -C "$srcdir" ls-files -z --cached --others --exclude-standard --deduplicate)
}

# True when the link target lies in a legacy root other than the tree in use.
is_legacy_link_target() {
  local root
  for root in "${VEKRONA_LEGACY_ROOTS[@]}"; do
    [[ "$root" != "$VEKRONA_ROOT" && "$1" == "$root"/* ]] && return 0
  done
  return 1
}

# Prints every symlink under the given dirs whose raw target is under this checkout or a legacy root; with
# --stale, only those that should not exist: the target is gone, git ignores it in this checkout (an earlier
# install linked build junk), or it lies in a legacy root. A dir that is itself a symlink is someone else's.
vekrona_links() {
  local stale=0 d link target
  [[ "${1:-}" == --stale ]] && { stale=1; shift; }
  for d in "$@"; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    while IFS= read -r -d '' link; do
      target="$(readlink "$link")"
      case "$target" in
        "$VEKRONA_ROOT"/*) ;;
        *) is_legacy_link_target "$target" || continue ;;
      esac
      if [[ $stale -eq 1 && -e "$link" ]]; then
        is_legacy_link_target "$target" || is_ignored_in_checkout "$target" || continue
      fi
      printf '%s\n' "$link"
    done < <(find "$d" -type l -print0)
  done
}

# Removes links into a vekrona checkout whose file is gone from it (renamed or deleted upstream) or is now
# git-ignored, and links still into the legacy root. ensure_symlink has already repointed every legacy link whose file
# exists in this checkout, so this only catches leftovers.
prune_vekrona_links() {
  local link
  while IFS= read -r link; do
    log "removing stale link: $link -> $(readlink "$link")"
    rm -f "$link"
    [[ ! -L "$link" ]] || die "failed to remove $link"
  done < <(vekrona_links --stale "$@")
}

# Every directory stage 50 links into, one per line (70-verify scans the same set). ~/.config/ghostty is
# listed only so prune_vekrona_links retires the config link earlier installs made there (vekrona no longer
# ships a Ghostty config); a dotfiles-managed or regular ~/.config/ghostty/config is never touched.
vekrona_link_dirs() {
  local d
  printf '%s\n' \
    "$HOME/.config/sway" "$HOME/.config/environment.d" "$HOME/.config/xremap" "$HOME/.config/ghostty" "$HOME/.config/autostart" \
    "$HOME/.config/systemd/user" "$HOME/.config/fontconfig/conf.d" \
    "$HOME/.config/quickshell" \
    "$HOME/.local/share/fonts/vekrona" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/scalable/apps" "$HOME/.local/bin" \
    "$HOME/.config/scopebuddy" "$HOME/.config/MangoHud" \
    "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"
  vekrona_webapp_profile_dirs
}

# Every vekrona-* Firefox webapp profile directory that exists, one per line.
vekrona_webapp_profile_dirs() {
  local root d
  root="$(firefox_profile_root)" || die "cannot resolve the Firefox profile root"
  for d in "$root"/vekrona-*; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done
  return 0
}

ensure_dir() {
  local d
  for d in "$@"; do [[ -d "$d" ]] || mkdir -p "$d"; done
}

# ensure_system_unit [--now] enabled|disabled <unit>...  With --now the unit's running state follows too (started
# when enabled, stopped when disabled). A masked or static unit cannot be enabled, so it already counts as disabled.
ensure_system_unit() {
  local now=""
  if [[ "${1:-}" == --now ]]; then now=1; shift; fi
  local state="$1"; shift
  local u
  for u in "$@"; do
    if ! unit_matches_state "$u" "$state"; then
      root systemctl "${state%d}" ${now:+--now} "$u" # enabled -> enable, disabled -> disable
      unit_matches_state "$u" "$state" || die "unit $u not $state"
    fi
    if [[ -n "$now" ]]; then
      case "$state" in
        enabled)  [[ "$(systemctl is-active "$u" 2>/dev/null || true)" == active ]] || root systemctl start "$u" ;;
        disabled) [[ "$(systemctl is-active "$u" 2>/dev/null || true)" != active ]] || root systemctl stop "$u" ;;
      esac
    fi
    log "unit $u: $state"
  done
}

unit_matches_state() {
  local current
  current="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  case "$2" in
    enabled)  [[ "$current" == enabled ]] ;;
    disabled) [[ "$current" == disabled || "$current" == masked || "$current" == static ]] ;;
    *) die "unknown unit state: $2" ;;
  esac
}

# The hardware clock must hold UTC: with local time in the RTC, early-boot journal timestamps are off by the zone
# offset and the clock steps once timesyncd runs.
rtc_is_utc() { [[ "$(timedatectl show -p LocalRTC --value)" == no ]]; }

ensure_utc_rtc() {
  if rtc_is_utc; then log "hardware clock: UTC"; return 0; fi
  log "hardware clock holds local time: switching it to UTC"
  root timedatectl set-local-rtc 0
  rtc_is_utc || die "hardware clock still not UTC after timedatectl set-local-rtc 0"
}

ensure_system_unit_active() {
  local u
  for u in "$@"; do
    if [[ "$(systemctl is-active "$u" 2>/dev/null || true)" == active ]]; then log "unit active: $u"; continue; fi
    root systemctl start "$u"
    [[ "$(systemctl is-active "$u" 2>/dev/null || true)" == active ]] || die "unit not active: $u"
  done
}

# Quickshell never removes the runtime directory (logs, ipc socket) of an instance that has exited.
prune_dead_quickshell_instances() {
  local runtime="$1" pid_link instance_dir removed=0
  [[ -d "$runtime/by-id" ]] || return 0
  local -A live=()
  for pid_link in "$runtime"/by-pid/*; do
    [[ -L "$pid_link" ]] || continue
    if kill -0 "${pid_link##*/}" 2>/dev/null; then
      live["$(basename "$(readlink "$pid_link")")"]=1
    else
      rm -f "$pid_link"
    fi
  done
  for instance_dir in "$runtime"/by-id/*; do
    [[ -d "$instance_dir" && -z "${live[${instance_dir##*/}]:-}" ]] || continue
    rm -rf "$instance_dir"
    removed=$((removed + 1))
  done
  log "removed $removed dead Quickshell instance directories"
}

ensure_user_unit_enabled() {
  local u
  for u in "$@"; do
    if [[ "$(systemctl --user is-enabled "$u" 2>/dev/null || true)" == "enabled" ]]; then log "user unit enabled: $u"; continue; fi
    systemctl --user daemon-reload
    systemctl --user enable "$u"
    [[ "$(systemctl --user is-enabled "$u" 2>/dev/null || true)" == "enabled" ]] || die "user unit not enabled: $u"
  done
}

ensure_user_unit_stopped() {
  local u
  for u in "$@"; do
    [[ "$(systemctl --user show -p LoadState --value "$u")" == loaded ]] || { log "user unit not loaded: $u"; continue; }
    log "stopping and disabling: $u"
    systemctl --user disable --now "$u" || die "cannot stop $u"
  done
}

ensure_user_in_group() {
  local group="$1"
  getent group "$group" >/dev/null || die "group missing: $group"
  if id -nG "$VEKRONA_USER" | tr ' ' '\n' | grep -qx "$group"; then log "$VEKRONA_USER in $group"; return 0; fi
  log "adding $VEKRONA_USER to $group (re-login required)"
  root usermod -aG "$group" "$VEKRONA_USER"
  getent group "$group" | grep -q "\b$VEKRONA_USER\b" || die "user not added to $group"
}

vekrona_sysfs() { printf '%s' "${VEKRONA_SYSFS_ROOT:-}/sys"; }

pci_has_id() {
  local want="$1" dev
  for dev in "$(vekrona_sysfs)"/bus/pci/devices/*/; do
    [[ -r "$dev/vendor" && -r "$dev/device" ]] || continue
    [[ "$(<"$dev/vendor"):$(<"$dev/device")" == "0x${want%%:*}:0x${want##*:}" ]] && return 0
  done
  return 1
}

pci_display_vendors() {
  local dev
  for dev in "$(vekrona_sysfs)"/bus/pci/devices/*/; do
    [[ -r "$dev/vendor" && -r "$dev/class" ]] || continue
    [[ "$(<"$dev/class")" == 0x03* ]] && cat "$dev/vendor"
  done
  return 0
}

pci_display_ids() {
  local dev
  for dev in "$(vekrona_sysfs)"/bus/pci/devices/*/; do
    [[ -r "$dev/vendor" && -r "$dev/device" && -r "$dev/class" ]] || continue
    [[ "$(<"$dev/class")" == 0x03* ]] && printf '%s:%s\n' "$(<"$dev/vendor")" "$(<"$dev/device")"
  done
  return 0
}

dmi_field() { cat "$(vekrona_sysfs)/class/dmi/id/$1" 2>/dev/null || true; }

has_nvidia_gpu() {
  local vendors
  vendors="$(pci_display_vendors)"
  grep -qx 0x10de <<<"$vendors"
}

is_apple_mac() { [[ "$(dmi_field sys_vendor)" == "Apple Inc." ]]; }

has_broadcom_wl_wifi() { pci_has_id 14e4:43a0; }

has_brcmfmac_43602() { pci_has_id 14e4:43ba; }

is_macbookpro12_1() { [[ "$(dmi_field product_name)" == "MacBookPro12,1" ]]; }

has_facetime_hd_camera() { pci_has_id 14e4:1570; }

has_apple_gmux_dual_gpu() { is_apple_mac && [[ "$(pci_display_vendors | wc -l)" -gt 1 ]]; }

is_laptop() {
  case "$(dmi_field chassis_type)" in 8|9|10|14) return 0 ;; *) return 1 ;; esac
}

# The proprietary 615 module drives Turing..Ada only: pre-Turing (Maxwell, Pascal, Volta) was dropped after the 580
# branch, and Blackwell needs the open module with GSP, which this setup turns off.
NVIDIA_FIRST_SUPPORTED_ID=0x1e00
NVIDIA_FIRST_UNSUPPORTED_ID=0x2900
AKMODS_PUBLIC_KEY=/etc/pki/akmods/certs/public_key.der

# Prints "10de:XXXX" for every NVIDIA display device outside the supported range, or with a malformed ID.
unsupported_nvidia_ids() {
  local id device
  while read -r id; do
    [[ "${id%%:*}" == 0x10de ]] || continue
    device="${id##*:}"
    if [[ "$device" =~ ^0x[0-9a-fA-F]{4}$ ]] \
      && ((device >= NVIDIA_FIRST_SUPPORTED_ID && device < NVIDIA_FIRST_UNSUPPORTED_ID)); then continue; fi
    printf '10de:%s\n' "${device#0x}"
  done < <(pci_display_ids)
}

# Prints why akmods modules would not load under Secure Boot, or why that cannot be verified; nothing when fine.
secure_boot_problem() {
  local state sb_state_ok enrolled key="${VEKRONA_SYSFS_ROOT:-}$AKMODS_PUBLIC_KEY"
  [[ -d "$(vekrona_sysfs)/firmware/efi" ]] || return 0 # booted without UEFI: no Secure Boot
  command -v mokutil >/dev/null || { echo "mokutil is not installed, cannot verify Secure Boot (run: sudo dnf install mokutil, then rerun install.sh)"; return 0; }
  state="$(mokutil --sb-state 2>&1)" && sb_state_ok=1 || sb_state_ok=0 # firmware without Secure Boot support answers on stderr and exits non-zero
  case "$state" in
    *"SecureBoot disabled"*|*"doesn't support Secure Boot"*) return 0 ;;
  esac
  [[ "$sb_state_ok" == 1 ]] || { echo "mokutil --sb-state failed ($state), cannot verify Secure Boot"; return 0; }
  case "$state" in
    *"SecureBoot enabled"*) ;;
    *) echo "unexpected mokutil --sb-state output ($state), cannot verify Secure Boot"; return 0 ;;
  esac
  if [[ -e "$key" ]]; then
    enrolled="$(mokutil --test-key "$key" 2>&1 || true)" # judged by its output: it exits non-zero when not enrolled
  else
    enrolled="is not enrolled"
  fi
  case "$enrolled" in
    *"is already enrolled"*) ;;
    *"is not enrolled"*) echo "Secure Boot is enabled and the akmods key $AKMODS_PUBLIC_KEY is not enrolled, so a built nvidia module would not load" ;;
    *) echo "unexpected mokutil --test-key output ($enrolled), cannot verify the akmods key" ;;
  esac
}

# Prints why stage 10-nvidia must not run on a non-Mac with an NVIDIA GPU; nothing when it may.
# RPM Fusion's xorg-x11-drv-nvidia %posttrans blacklists nouveau on install, so this decides before any package.
nvidia_stage_refusal() {
  local ids
  ids="$(unsupported_nvidia_ids | paste -sd' ')"
  if [[ -n "$ids" ]]; then
    echo "NVIDIA GPU $ids is outside the supported range $NVIDIA_FIRST_SUPPORTED_ID-$NVIDIA_FIRST_UNSUPPORTED_ID (exclusive)"
  else
    secure_boot_problem
  fi
}

wants_nvidia_stage() { has_nvidia_gpu && ! is_apple_mac && [[ -z "$(nvidia_stage_refusal)" ]]; }

warn_if_nvidia_stage_refused() {
  local reason
  has_nvidia_gpu && ! is_apple_mac || return 0
  reason="$(nvidia_stage_refusal)"
  [[ -z "$reason" ]] || warn "stage 10-nvidia skipped: $reason; keeping nouveau"
}

stage_applies() {
  case "$1" in
    10-nvidia) wants_nvidia_stage ;;
    15-mac) is_apple_mac ;;
    *) return 0 ;;
  esac
}

wants_usb_autosuspend_dropin() { ! is_laptop; }

installed_kvers() {
  local kvers
  kvers="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n')" || die "kernel-core is not installed"
  [[ -n "$kvers" ]] || die "no installed kernel-core versions found"
  sort -V <<<"$kvers"
}

newest_installed_kver() {
  local kvers
  kvers="$(installed_kvers)" || exit 1
  tail -1 <<<"$kvers"
}

assert_running_kernel_is_latest() {
  local running latest
  running="$(uname -r)"
  latest="$(newest_installed_kver)"
  [[ "$latest" == "$running" ]] || die "reboot into the latest installed kernel first (running $running, latest installed $latest)"
}

ensure_target_kernel_devel() {
  assert_running_kernel_is_latest
  ensure_pkg "kernel-devel-$(newest_installed_kver)"
}

AKMODS_WAIT_SECONDS=900

# An akmod-* RPM's posttrans starts a background akmods that takes its lock only after its init, so the lock alone
# can be won before that build exists. akmods is a bash script, so its process name (comm) is "akmods".
# pidwait exits 1 when no such process runs.
wait_for_running_akmods() {
  local status=0
  require_cmd pidwait timeout
  timeout "$AKMODS_WAIT_SECONDS" pidwait -x akmods || status=$?
  case "$status" in
    0 | 1) ;;
    124) die "timed out after $AKMODS_WAIT_SECONDS s waiting for a running akmods build" ;;
    *) die "waiting for a running akmods build failed with status $status" ;;
  esac
}

build_akmods_for_target_kernel() {
  local target_kver
  target_kver="$(uname -r)"
  require_cmd akmods
  ensure_target_kernel_devel
  log "rebuilding akmods for $target_kver"
  root akmods --force --kernels "$target_kver"
}

with_scratch_dir() {
  (
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    "$@" "$scratch"
  )
}

# The one download chokepoint. Retries transient failures (DNS, connect, 5xx): redirectors such as
# mirrors.rpmfusion.org hand out a different mirror per request, so a retry usually lands on a healthy one.
download_file() {
  local url="$1" dest="$2"
  require_cmd curl
  curl --fail --silent --show-error --location --retry 5 --retry-all-errors --connect-timeout 20 \
    --output "$dest" "$url" || die "download failed: $url"
}

fetch_pinned() {
  local url="$1" sha256="$2" dest="$3" actual
  require_cmd sha256sum
  log "fetching: $url"
  download_file "$url" "$dest"
  actual="$(sha256sum "$dest" | awk '{print $1}')"
  [[ "$actual" == "$sha256" ]] || die "sha256 mismatch for $url (expected $sha256, got $actual)"
}

ensure_root_file_absent() {
  local dst="$1"
  [[ -e "$dst" ]] || { log "absent: $dst"; return 0; }
  log "removing: $dst"
  root rm -f "$dst"
  [[ ! -e "$dst" ]] || die "failed to remove $dst"
}

owned_by() { [[ "$(stat -c '%U' "$1" 2>/dev/null)" == "$2" ]]; }
dir_mode_is() { [[ "$(stat -c '%a' "$1" 2>/dev/null)" == "$2" ]]; }

VEKRONA_REPO_KEY_DIR=/etc/pki/rpm-gpg

# shellcheck disable=SC2034
CLAUDE_CODE_REPO_ID="claude-code"
# shellcheck disable=SC2034
MISE_REPO_ID="mise-repo"

declare -A VEKRONA_REPO_KEY_FINGERPRINTS=(
  [claude-code]="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
  [mise]="24853EC9F655CE80B48E6C3A8B81C9D17413A06D"
  [1password]="3FEF9748469ADBE15DA7CA80AC2D62742012EA22"
  [rpmfusion-free-fedora-44]="E9A491A3DE247814E7E067EAE06F8ECDD651FF2E"
  [rpmfusion-nonfree-fedora-44]="79BDB88F9BBF73910FD4095B6A2AF96194843C65"
)

repo_key_name() { printf 'RPM-GPG-KEY-%s' "$1"; }

rpmfusion_key_repo() { printf 'rpmfusion-%s-fedora-%s' "$1" "$(rpm -E %fedora)"; }

rpmfusion_release_url() {
  local section="$1"
  printf 'https://mirrors.rpmfusion.org/%s/fedora/rpmfusion-%s-release-%s.noarch.rpm' "$section" "$section" "$(rpm -E %fedora)"
}

rpmfusion_repo_file_uses_pinned_key() {
  local section="$1" lines
  lines="$(grep '^gpgkey=' "/etc/yum.repos.d/rpmfusion-$section.repo" | sort -u)"
  [[ "$lines" == "gpgkey=file://$VEKRONA_REPO_KEY_DIR/RPM-GPG-KEY-rpmfusion-$section-fedora-\$releasever" ]]
}

key_file_primary_fingerprints() {
  local file="$1" scratch_gnupg_home listing
  scratch_gnupg_home="$(mktemp -d)"
  listing="$(gpg --homedir "$scratch_gnupg_home" --batch --with-colons --import-options show-only --import "$file" 2>&1)" \
    || { rm -rf "$scratch_gnupg_home"; die "cannot read gpg key file $file: $listing"; }
  rm -rf "$scratch_gnupg_home"
  awk -F: '/^pub:/{want=1; next} /^fpr:/&&want{print $10; want=0}' <<<"$listing"
}

assert_repo_key_file_pinned() {
  local repo="$1" file="$2" found
  [[ -v "VEKRONA_REPO_KEY_FINGERPRINTS[$repo]" ]] || die "no pinned gpg key fingerprint for repo: $repo; verify its key out of band (docs/agents.md), vendor it as etc/pki/rpm-gpg/$(repo_key_name "$repo") and pin the fingerprint in VEKRONA_REPO_KEY_FINGERPRINTS in lib/common.sh"
  local expected="${VEKRONA_REPO_KEY_FINGERPRINTS[$repo]}"
  found="$(key_file_primary_fingerprints "$file")"
  [[ "$found" == "$expected" ]] || die "gpg key file for repo '$repo' ($file) must hold exactly one primary key with fingerprint $expected, found: ${found//$'\n'/ }; if the vendor rotated its key, verify the new fingerprint out of band, then update VEKRONA_REPO_KEY_FINGERPRINTS and etc/pki/rpm-gpg/$(repo_key_name "$repo") together"
}

assert_rpm_signed_by_pinned_key() {
  local repo="$1" rpm_file="$2" key_file keyring result
  key_file="$VEKRONA_ROOT/etc/pki/rpm-gpg/$(repo_key_name "$repo")"
  assert_repo_key_file_pinned "$repo" "$key_file"
  require_cmd rpmkeys
  keyring="$(mktemp -d)"
  rpmkeys --dbpath "$keyring" --import "$key_file" \
    || { rm -rf "$keyring"; die "cannot import the pinned gpg key $key_file into a scratch rpm keyring"; }
  result="$(rpmkeys --dbpath "$keyring" --checksig -v "$rpm_file" 2>&1)" \
    || { rm -rf "$keyring"; die "$rpm_file is not validly signed by the pinned key of repo '$repo' (${VEKRONA_REPO_KEY_FINGERPRINTS[$repo]}, $key_file): ${result//$'\n'/ | }"; }
  rm -rf "$keyring"
}

gpg_pubkey_installed() {
  # rpm records a gpg-pubkey's full fingerprint as %{VERSION}, not the 8-hex short key id.
  local fingerprint_lower="$1" keys
  keys="$(rpm -q gpg-pubkey --qf '%{VERSION}\n' 2>/dev/null | tr '[:upper:]' '[:lower:]')" || return 1
  grep -qx -- "$fingerprint_lower" <<<"$keys"
}

repo_key_in_rpm_keyring() {
  local repo="$1" fingerprint_lower
  fingerprint_lower="$(tr '[:upper:]' '[:lower:]' <<<"${VEKRONA_REPO_KEY_FINGERPRINTS[$repo]}")"
  gpg_pubkey_installed "$fingerprint_lower"
}

assert_repo_key_trusted() {
  local repo="$1"
  assert_repo_key_file_pinned "$repo" "$VEKRONA_REPO_KEY_DIR/$(repo_key_name "$repo")"
  repo_key_in_rpm_keyring "$repo" || die "rpm keyring lacks the pinned gpg key for repo '$repo': ${VEKRONA_REPO_KEY_FINGERPRINTS[$repo]}"
}

ensure_1password_repo_file() {
  ensure_root_file "$VEKRONA_ROOT/etc/yum.repos.d/1password.repo" /etc/yum.repos.d/1password.repo
}

import_pinned_repo_key() {
  local repo="$1" key_file="$2"
  assert_repo_key_file_pinned "$repo" "$key_file"
  if repo_key_in_rpm_keyring "$repo"; then
    log "gpg key already imported for repo $repo"
  else
    log "importing gpg key for repo $repo"
    root rpm --import "$key_file"
  fi
}

ensure_repo_key() {
  local repo="$1" src dst
  ensure_pkg gnupg2
  src="$VEKRONA_ROOT/etc/pki/rpm-gpg/$(repo_key_name "$repo")"
  dst="$VEKRONA_REPO_KEY_DIR/$(repo_key_name "$repo")"
  assert_repo_key_file_pinned "$repo" "$src"
  ensure_root_file "$src" "$dst"
  import_pinned_repo_key "$repo" "$dst"
  assert_repo_key_trusted "$repo"
}

# shellcheck disable=SC2034
VEKRONA_AGENT_PKGS=(claude-code mise nodejs24-npm)
# shellcheck disable=SC2034
VEKRONA_AGENT_TOOLS=(codex pi opencode cursor-agent)

MISE_SYSTEM_DATA_DIR=/usr/local/share/mise
MISE_SYSTEM_CONFIG_DIR=/etc/mise
MISE_SYSTEM_CACHE_DIR=/usr/local/share/mise/cache
MISE_SYSTEM_STATE_DIR=/usr/local/share/mise/state
MISE_SYSTEM_SHIMS_DIR="$MISE_SYSTEM_DATA_DIR/shims"
MISE_NPM_MIN_RELEASE_AGE_VERSION=11.10.0
CLAUDE_BIN=/usr/bin/claude

managed_binary() {
  case "$1" in
    claude) printf '%s' "$CLAUDE_BIN" ;;
    *) printf '%s/%s' "$MISE_SYSTEM_SHIMS_DIR" "$1" ;;
  esac
}

mise_system() {
  # mise silently ignores /etc/mise/config.toml ("all tools are installed") while its HOME does not exist yet.
  root mkdir -p "$MISE_SYSTEM_DATA_DIR"
  # mise --system only installs binary-download backends; overriding MISE_DATA_DIR/MISE_CONFIG_DIR
  # instead runs the normal (non-system) code path against root-owned dirs, which also covers our npm/aqua/http tools.
  # sudo resets HOME to /root; pin HOME and every cache path so npm/mise never write outside this tree.
  root env -u MISE_MINIMUM_RELEASE_AGE \
    HOME="$MISE_SYSTEM_DATA_DIR" \
    MISE_DATA_DIR="$MISE_SYSTEM_DATA_DIR" \
    MISE_CONFIG_DIR="$MISE_SYSTEM_CONFIG_DIR" \
    MISE_CACHE_DIR="$MISE_SYSTEM_CACHE_DIR" \
    MISE_STATE_DIR="$MISE_SYSTEM_STATE_DIR" \
    npm_config_cache="$MISE_SYSTEM_DATA_DIR/npm-cache" \
    mise "$@"
}

mise_system_strict() {
  local output status=0
  output="$(mktemp)"
  mise_system "$@" 2>&1 | tee "$output" >&2 || status=$?
  if grep -q 'minimum_release_age is set for' "$output"; then
    rm -f "$output"
    die "mise $* cannot enforce minimum_release_age (see the warning above): the 1-day cooldown would not cover transitive dependencies"
  fi
  rm -f "$output"
  [[ $status -eq 0 ]] || die "mise $* failed with exit status $status"
}

version_at_least() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }

assert_npm_supports_release_age() {
  local version
  version="$(npm --version)" || die "npm --version failed"
  version_at_least "$version" "$MISE_NPM_MIN_RELEASE_AGE_VERSION" \
    || die "npm $version is older than $MISE_NPM_MIN_RELEASE_AGE_VERSION, which mise needs to apply minimum_release_age to npm dependencies"
}

assert_tree_root_owned_not_writable() {
  local dir="$1" offenders
  offenders="$(root find "$dir" \( ! -user root -o \( ! -type l -perm /022 \) \) -print)" || die "cannot scan $dir"
  [[ -z "$offenders" ]] || die "$dir has entries not owned by root or writable by group/other, first: $(head -n 5 <<<"$offenders" | tr '\n' ' ')"
  log "ok: $dir is root-owned and not group/other-writable throughout"
}

root_owned_not_writable_file() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] && owned_by "$file" root && (( (8#$(stat -c '%a' "$file") & 022) == 0 ))
}

VERSIONLOCK_FILE=/etc/dnf/versionlock.toml

versionlock_has() { [[ -e "$VERSIONLOCK_FILE" ]] && file_grep_q -E "^name = \"$1\"" "$VERSIONLOCK_FILE"; }

versionlock_evrs() {
  [[ -e "$VERSIONLOCK_FILE" ]] || return 0
  sed -nE 's/^value = "(.*)"$/\1/p' "$VERSIONLOCK_FILE"
}

versionlock_installed() {
  local p
  for p in "$@"; do
    pkg_installed "$p" || die "refusing to lock a package that is not installed: $p"
    if versionlock_has "$p"; then log "locked: $p"; continue; fi
    log "locking: $p"
    root dnf versionlock add "$p"
    versionlock_has "$p" || die "lock not recorded in $VERSIONLOCK_FILE: $p"
  done
}

versionlock_absent() {
  local p
  for p in "$@"; do
    versionlock_has "$p" || { log "not locked: $p"; continue; }
    log "unlocking: $p"
    root dnf versionlock delete "$p"
    ! versionlock_has "$p" || die "lock still recorded in $VERSIONLOCK_FILE: $p"
  done
}

# Exact whole-token lookup in a file in kernel command line format.
cmdline_file_has() {
  local file="$1" arg="$2" words w
  [[ -r "$file" ]] || die "cannot read kernel command line file: $file"
  read -ra words < "$file" || true
  for w in "${words[@]}"; do [[ "$w" == "$arg" ]] && return 0; done
  return 1
}

kernel_cmdline_has() { cmdline_file_has "${VEKRONA_SYSFS_ROOT:-}/proc/cmdline" "$1"; }

grubby_has_arg() {
  local arg="$1" info
  info="$(root grubby --info=ALL)" || die "grubby --info=ALL failed"
  awk -v a="$arg" '
    /^args=/ { n=split($0, w, /[ "]/); for (i=1;i<=n;i++) if (w[i]==a) found=1 }
    END { exit !found }
  ' <<<"$info"
}

# Every kernel arg stage 10 ensures and 70-verify checks, one per line; the blacklist spelling is RPM Fusion's own.
# pcie_aspm=off stays on desktops only: it costs laptops battery.
nvidia_kernel_args() {
  printf '%s\n' nvidia.NVreg_EnableGpuFirmware=0
  is_laptop || printf '%s\n' pcie_aspm=off
  printf '%s\n' 'rd.driver.blacklist=nouveau,nova_core' 'modprobe.blacklist=nouveau,nova_core'
}

# Prints active (on the running cmdline), pending (in grubby, needs a reboot) or missing.
kernel_arg_state() {
  if kernel_cmdline_has "$1"; then echo active
  elif grubby_has_arg "$1"; then echo pending
  else echo missing
  fi
}

nvidia_module_license() { modinfo -k "$1" -F license nvidia 2>/dev/null || true; }

# Prints what is wrong with the kernel's nvidia module (the proprietary one has license NVIDIA); nothing when fine.
nvidia_module_problem() {
  local license
  license="$(nvidia_module_license "$1")"
  if [[ -z "$license" ]]; then echo "nvidia module missing or unreadable for $1 (license '')"
  elif [[ "$license" != NVIDIA ]]; then echo "nvidia module for $1 has license '$license', expected NVIDIA"
  fi
}

DRACUT_NVIDIA_CONF=/etc/dracut.conf.d/99-nvidia-dracut.conf
NVIDIA_MODPROBE_CONF=/etc/modprobe.d/vekrona-nvidia.conf

initramfs_path() { printf '%s/boot/initramfs-%s.img' "${VEKRONA_SYSFS_ROOT:-}" "$1"; }

initramfs_has_nvidia() {
  local img listing
  img="$(initramfs_path "$1")"
  listing="$(root lsinitrd "$img")" || die "lsinitrd failed for $img"
  grep -qE '/nvidia\.ko(\.[a-z0-9]+)?$' <<<"$listing"
}

# nvidia loads from the initramfs, where dracut copies /etc/modprobe.d, so its options only apply from the image.
initramfs_has_nvidia_options() {
  local img packed
  img="$(initramfs_path "$1")"
  packed="$(root lsinitrd "$img" -f "${NVIDIA_MODPROBE_CONF#/}")" || die "lsinitrd -f ${NVIDIA_MODPROBE_CONF#/} failed for $img"
  [[ "$packed" == "$(<"${VEKRONA_SYSFS_ROOT:-}$NVIDIA_MODPROBE_CONF")" ]]
}

# True once the loaded nvidia module runs with NVreg_UseKernelSuspendNotifiers=0 (false while that is pending a reboot).
nvidia_suspend_notifiers_off() {
  local params="${VEKRONA_SYSFS_ROOT:-}/proc/driver/nvidia/params"
  [[ -e "$params" ]] && file_grep_q -x 'UseKernelSuspendNotifiers: 0' "$params"
}

# True when the initramfs is absent, lacks nvidia, or predates the module or a config file that dracut bakes into it.
initramfs_needs_nvidia_regen() {
  local img module input
  img="$(initramfs_path "$1")"
  [[ -e "$img" ]] || return 0
  module="$(modinfo -k "$1" -n nvidia)" || die "nvidia module missing for $1"
  for input in "$module" "${VEKRONA_SYSFS_ROOT:-}$DRACUT_NVIDIA_CONF" "${VEKRONA_SYSFS_ROOT:-}$NVIDIA_MODPROBE_CONF"; do
    [[ "$img" -ot "$input" ]] && return 0
  done
  initramfs_has_nvidia "$1" && return 1
  return 0
}

# akmods@<kver> (started by kernel-install's akmods hook) must regenerate that kernel's initramfs once the module exists.
akmods_dropin_active() {
  local unit
  unit="$(systemctl cat "akmods@$1.service")" || die "cannot read unit akmods@$1.service"
  grep -qxF 'ExecStartPost=/usr/bin/dracut -f --kver %i' <<<"$unit"
}

ensure_kernel_arg() {
  local arg file="${VEKRONA_SYSFS_ROOT:-}/etc/kernel/cmdline"
  for arg in "$@"; do
    if grubby_has_arg "$arg" && [[ -e "$file" ]] && cmdline_file_has "$file" "$arg"; then log "kernel arg present: $arg"; continue; fi
    log "adding kernel arg: $arg"
    root grubby --update-kernel=ALL --args="$arg"
    grubby_has_arg "$arg" || die "kernel arg not applied by grubby: $arg"
    cmdline_file_has "$file" "$arg" || die "kernel arg not in /etc/kernel/cmdline: $arg"
  done
}

session_is_sway() { [[ "${XDG_CURRENT_DESKTOP:-}" == "sway" ]]; }

session_started_by_gdm() { [[ "$(systemctl is-active gdm 2>/dev/null || true)" == "active" ]]; }

dm_unit_target() {
  local f=/etc/systemd/system/display-manager.service
  [[ -e "$f" ]] && basename "$(readlink -f "$f")"
}

dm_is_greetd() { [[ "$(dm_unit_target 2>/dev/null || true)" == greetd.service ]]; }

default_target_is_graphical() { [[ "$(systemctl get-default)" == graphical.target ]]; }

greetd_enabled() { [[ "$(systemctl is-enabled greetd 2>/dev/null || true)" == enabled ]]; }

enable_greetd_login_manager() {
  if greetd_enabled; then
    log "greetd already enabled"
  else
    root systemctl enable --force greetd
  fi
  if default_target_is_graphical; then
    log "default target already graphical.target"
  else
    root systemctl set-default graphical.target
  fi
  assert "greetd enabled" greetd_enabled
  assert "display-manager.service points to greetd" dm_is_greetd
  assert "default target is graphical.target" default_target_is_graphical
}

assert() {
  local msg="$1"; shift
  if "$@"; then log "ok: $msg"; else die "assertion failed: $msg"; fi
}

assert_file_contains() {
  local file="$1" pattern="$2"
  file_grep_q -E -- "$pattern" "$file" || die "$file does not match: $pattern"
  log "ok: $file matches $pattern"
}

wlroots_package_name() {
  local requires soname out p
  requires="$(rpm -q --requires sway)" || die "sway must be installed before resolving its wlroots package"
  soname="$(grep -m1 '^libwlroots' <<<"$requires")" || die "installed sway requires no libwlroots soname"
  if ! out="$(rpm -q --whatprovides "$soname" --qf '%{NAME}\n' 2>&1)"; then
    die "no installed package provides $soname: $out"
  fi
  p="$(sort -u <<<"$out" | head -n1)"
  [[ -n "$p" ]] || die "no installed package provides $soname"
  printf '%s' "$p"
}

read_pkg_list() {
  local -n out_arr="$1"
  shift
  local raw line
  raw="$("$@")"
  out_arr=()
  while IFS= read -r line; do
    out_arr+=("$line")
  done <<< "$raw"
}

# shellcheck disable=SC2034
VEKRONA_COPRS=(blakegardner/xremap scottames/ghostty avengemedia/danklinux rossetnocpes/herdr)

copr_id() { echo "copr:copr.fedorainfracloud.org:${1/\//:}"; }

# shellcheck disable=SC2034
VEKRONA_FLATPAKS=(dev.zed.Zed org.signal.Signal com.obsproject.Studio md.obsidian.Obsidian)

# shellcheck disable=SC2034
VEKRONA_X11_FLATPAKS=(org.signal.Signal)

# shellcheck disable=SC2034
declare -A VEKRONA_PINNED_PKGS=(
  [quickshell]="$(copr_id avengemedia/danklinux)"
  [herdr]="$(copr_id rossetnocpes/herdr)"
)

VEKRONA_DESKTOP_PKGS=(
  adw-gtk3-theme 1password 1password-cli NetworkManager NetworkManager-wifi accountsservice atkinson-hyperlegible-next-fonts bluez brightnessctl btop cliphist
  dconf ffmpeg firefox flatpak gamemode gamescope ghostty
  geoclue2 geoclue2-libs gnome-keyring gnome-keyring-pam greetd grim gstreamer1-plugin-libav gstreamer1-plugin-openh264 gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly herdr inotify-tools intel-media-driver
  jq kanshi khal
  libnotify mangohud mesa-va-drivers-freeworld mozilla-openh264 nix nix-daemon openh264 perl-interpreter pipewire pipewire-pulseaudio playerctl polkit
  python3 python3-gobject python3-pyyaml python3-vdf qalculate qt6ct quickshell rofi rsms-inter-fonts slurp steam swappy sway sway-config-fedora
  sway-systemd swayidle syncthing tailscale tuigreet tuned-ppd vdirsyncer wf-recorder wireplumber wl-clipboard wlr-randr wlsunset
  wpa_supplicant xdg-desktop-portal-gtk xdg-desktop-portal-wlr xdg-utils xremap-wlroots
)

# shellcheck disable=SC2034
VEKRONA_RETIRED_PKGS=(dms dms-cli dgop danksearch matugen)

vekrona_desktop_pkgs() {
  local wlroots_pkg
  wlroots_pkg="$(wlroots_package_name)"
  printf '%s\n' "${VEKRONA_DESKTOP_PKGS[@]}" "$wlroots_pkg"
}

VEKRONA_VERSIONLOCK_PKGS=(sway quickshell qt6-qtbase qt6-qtdeclarative qt6-qtwayland xremap-wlroots)

vekrona_versionlock_pkgs() {
  local wlroots_pkg
  wlroots_pkg="$(wlroots_package_name)"
  printf '%s\n' "${VEKRONA_VERSIONLOCK_PKGS[@]}" "$wlroots_pkg"
}

flatpak_installed() {
  local apps
  apps="$(flatpak list --app --columns=application 2>/dev/null)" || die "flatpak list failed"
  grep -qx -- "$1" <<<"$apps"
}

flatpak_remote_system_enabled() {
  local name="$1" line
  line="$(flatpak remotes --system --show-disabled --columns=name,options 2>/dev/null | awk -F'\t' -v n="$name" '$1==n')"
  [[ -n "$line" ]] || return 1
  [[ "$line" != *disabled* ]]
}

flatpak_remote_system_exists() {
  local name="$1"
  flatpak remotes --system --show-disabled --columns=name 2>/dev/null | grep -qx "$name"
}

ensure_flatpak_remote_system() {
  local name="$1" url="$2"
  if flatpak_remote_system_enabled "$name"; then
    log "flatpak remote present: $name"
    return 0
  fi
  if flatpak_remote_system_exists "$name"; then
    log "enabling flatpak remote: $name"
    root flatpak remote-modify --system --enable "$name"
  else
    log "adding flatpak remote: $name"
    root flatpak remote-add --if-not-exists --system "$name" "$url"
  fi
  flatpak_remote_system_enabled "$name" || die "flatpak remote not added or not enabled: $name"
}

ensure_flatpak_app_system() {
  local remote="$1" app_id="$2"
  flatpak_installed "$app_id" && { log "flatpak app present: $app_id"; return 0; }
  log "installing flatpak: $app_id"
  root flatpak install --system -y --noninteractive "$remote" "$app_id"
  flatpak_installed "$app_id" || die "flatpak app not installed: $app_id"
}

# vekrona_token_get <group> <name> [mode]: one value of config/tokens.json. The color group needs a
# mode (dark|light); the others take none. A trailing "px" is stripped.
vekrona_token_get() {
  local group="$1" name="$2" mode="${3:-}" value
  case "$group" in
    color) [[ "$mode" == dark || "$mode" == light ]] || die "vekrona_token_get color $name: mode must be dark or light, got '$mode'" ;;
    spacing | border | size | opacity) [[ -z "$mode" ]] || die "vekrona_token_get $group $name: only color tokens have a mode, got '$mode'" ;;
    *) die "vekrona_token_get: unknown token group '$group'" ;;
  esac
  value="$(jq -er --arg g "$group" --arg n "$name" --arg m "$mode" \
    '.[$g].tokens[] | select(.name == $n) | if $g == "color" then .value[$m] else .value end | tostring | sub("px$"; "")' \
    "$VEKRONA_ROOT/config/tokens.json")" || die "config/tokens.json: no $group token '$name'${mode:+ for mode $mode}"
  printf '%s' "$value"
}

vekrona_state_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/vekrona"; }
vekrona_theme_name_file() { printf '%s' "$(vekrona_state_dir)/theme"; }
vekrona_active_theme_file() { printf '%s' "$(vekrona_state_dir)/active-theme.json"; }

# What `xdg-open` (links in apps, the launcher's web results) hands web pages to: Firefox. xdg-settings would do
# the same through xdg-mime, but it first has to detect the desktop environment, which Sway is not one of.
VEKRONA_BROWSER_DESKTOP=org.mozilla.firefox.desktop
VEKRONA_BROWSER_MIMES=(x-scheme-handler/http x-scheme-handler/https text/html)

ensure_default_browser() {
  local mime current
  for mime in "${VEKRONA_BROWSER_MIMES[@]}"; do
    current="$(xdg-mime query default "$mime")" || die "xdg-mime query failed: $mime"
    [[ "$current" == "$VEKRONA_BROWSER_DESKTOP" ]] && { log "default handler already set: $mime"; continue; }
    log "setting default handler: $mime = $VEKRONA_BROWSER_DESKTOP"
    xdg-mime default "$VEKRONA_BROWSER_DESKTOP" "$mime" || die "xdg-mime default failed: $mime"
    current="$(xdg-mime query default "$mime")"
    [[ "$current" == "$VEKRONA_BROWSER_DESKTOP" ]] || die "default handler not applied: $mime (is $current)"
  done
}

# The directory holding profiles.ini; one implementation (lib/vekrona_firefox.py) serves the renderer and the stages.
firefox_profile_root() { "$VEKRONA_ROOT/bin/vekrona-firefox" profile-root; }

whitespace_normalized() { local -a f; read -r -a f <<<"$1"; printf '%s' "${f[*]}"; }

fstab_line_for_mountpoint() {
  local mountpoint="$1" matches
  matches="$(awk -v m="$mountpoint" '$1 !~ /^#/ && NF >= 6 && $2 == m' /etc/fstab)"
  [[ -n "$matches" ]] || return 1
  [[ "$(wc -l <<<"$matches")" -eq 1 ]] || die "multiple fstab lines for mountpoint: $mountpoint"
  printf '%s' "$matches"
}

fstab_line_for_subvol() {
  local ref="$1" target="$2" subvol="$3"
  local line device fstype options dump pass
  line="$(fstab_line_for_mountpoint "$ref")" || die "no fstab line for mountpoint: $ref"
  read -r device _ fstype options dump pass <<<"$line"

  local -a opts=() new_opts=()
  IFS=',' read -r -a opts <<<"$options"
  local found=0 o
  for o in "${opts[@]}"; do
    if [[ "$o" == subvol=* ]]; then
      found=$((found + 1))
      new_opts+=("subvol=$subvol")
    else
      new_opts+=("$o")
    fi
  done
  [[ $found -eq 1 ]] || die "expected exactly one subvol= option in fstab line for $ref, found $found"

  local new_options
  IFS=','; new_options="${new_opts[*]}"; unset IFS
  printf '%s %s %s %s %s %s\n' "$device" "$target" "$fstype" "$new_options" "$dump" "$pass"
}

ensure_fstab_entry() {
  local mountpoint="$1" line="$2" existing
  if existing="$(fstab_line_for_mountpoint "$mountpoint")"; then
    if [[ "$(whitespace_normalized "$existing")" == "$(whitespace_normalized "$line")" ]]; then
      log "fstab entry present: $mountpoint"
      return 0
    fi
    die "fstab entry for $mountpoint differs, resolve manually: existing='$existing' wanted='$line'"
  fi
  log "appending fstab entry: $line"
  printf '%s\n' "$line" | root tee -a /etc/fstab >/dev/null
  existing="$(fstab_line_for_mountpoint "$mountpoint")" || die "fstab entry not written for $mountpoint"
  [[ "$(whitespace_normalized "$existing")" == "$(whitespace_normalized "$line")" ]] || die "fstab entry not written for $mountpoint"
}

root_btrfs_device() {
  local device
  device="$(findmnt -no SOURCE /)"
  device="${device%%\[*}"
  [[ -n "$device" ]] || die "could not determine btrfs device of /"
  printf '%s' "$device"
}

mount_btrfs_top_level() {
  local dir="$1"
  root mount -o subvolid=5 "$(root_btrfs_device)" "$dir"
}

is_btrfs_subvolume() { btrfs subvolume show "$1" >/dev/null 2>&1; }

btrfs_migrate_dir_into_subvolume() {
  local subvol="$1" src="${2:-}"
  local marker="$subvol/.vekrona-migrated"

  if is_btrfs_subvolume "$subvol"; then
    [[ -e "$marker" ]] || die "subvolume exists without migration marker (interrupted migration?): $subvol — inspect it, delete it with 'sudo btrfs subvolume delete <path>' (mount the top-level subvolume with subvolid=5 to reach it), then re-run ./install.sh 20; the source directory, if present, is untouched"
    log "subvolume already migrated: $subvol"
    return 0
  fi
  [[ -e "$subvol" ]] && die "path exists but is not a btrfs subvolume: $subvol"

  log "creating subvolume: $subvol"
  root btrfs subvolume create "$subvol"
  root chown root:root "$subvol"
  root chmod 0755 "$subvol"

  if [[ -n "$src" ]]; then
    [[ -d "$src" ]] || die "source directory missing: $src"
    log "migrating $src into $subvol"
    root cp -a --reflink=always "$src/." "$subvol/"
    local diff_out diff_rc=0
    diff_out="$(root diff -rq --no-dereference "$src" "$subvol" 2>&1)" || diff_rc=$?
    [[ $diff_rc -eq 0 ]] || die "migration verification failed for $subvol (diff exit $diff_rc): $diff_out"
  fi

  root touch "$marker"
}
