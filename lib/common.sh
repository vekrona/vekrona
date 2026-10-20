#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

VEKRONA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VEKRONA_ROOT
VEKRONA_USER="$(id -un)"
# Where earlier installs lived (a plain checkout, then install.sh's own clone); links into them are legacy and
# get repointed or pruned, unless that tree is the one running.
# Systemd system units have no $HOME: each one sets Environment=HOME=/root, and this fails loudly when it does not.
VEKRONA_LEGACY_ROOTS=("${HOME:?lib/common.sh needs HOME: a systemd system unit must set Environment=HOME=/root}/vekrona" "$HOME/.local/share/vekrona")
# Root-owned copy of the checkout's scripts: a unit cannot run from the 0700 user_home_t home directory.
VEKRONA_SYSTEM_DIR=/usr/local/lib/vekrona
# The bin/ scripts root runs from there: vekrona-proton from the update units, vekrona-update-ask as the user it asks.
# shellcheck disable=SC2034
VEKRONA_SYSTEM_BIN=(vekrona-proton vekrona-update-ask)

log()  { printf '\033[1;34m[vekrona]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[vekrona] WARN:\033[0m %s\n' "$*" >&2; }

VEKRONA_ERROR_REPORTER="${VEKRONA_ERROR_REPORTER:-$VEKRONA_ROOT/bin/vekrona-error}"

report_error_for_die() {
  timeout 5 "$VEKRONA_ERROR_REPORTER" report --title "$1" --source vekrona >/dev/null
}

# Every failure goes into the error stream and sends no notification: the robot's dot and list show it. The plain toast
# below is the last resort, for a failure that could not be recorded (docs/errors.md, "Where a plain toast is left").
# root has no desktop to toast on.
toast_unreported_error() {
  [[ $EUID -ne 0 ]] || return 0
  notify-send -u critical -a vekrona -- vekrona "$1" || warn "failed to show this error as a notification"
}

# Prints and records one failure and returns, for the code that must go on (a cleanup trap); die ends the command.
report_failure() {
  printf '\033[1;31m[vekrona] FAIL:\033[0m %s\n' "$*" >&2
  report_error_for_die "$*" || {
    warn "failed to report this error to vekrona-error"
    toast_unreported_error "$*"
  }
}

die() {
  report_failure "$*"
  exit 1
}

# Ends a command the person started the wrong way (as the wrong user, with Steam open) without recording an error: they
# read the reason in their terminal, and nothing on the system failed.
refuse() {
  printf '\033[1;31m[vekrona] REFUSED:\033[0m %s\n' "$*" >&2
  exit 2
}

root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

require_root() { [[ $EUID -eq 0 ]] || die "$(basename "$0") must run as root"; }

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
  local socket pid running=()
  if [[ -n "${SWAYSOCK:-}" ]] && swaymsg -s "$SWAYSOCK" -t get_version >/dev/null 2>&1; then
    printf '%s\n' "$SWAYSOCK"
    return 0
  fi
  for socket in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/sway-ipc.*.sock; do
    [[ -S "$socket" ]] || continue
    pid="${socket%.sock}"
    pid="${pid##*.}"
    [[ -d "/proc/$pid" ]] && running+=("$socket")
  done
  ((${#running[@]} <= 1)) || die "more than one running sway session, cannot tell which to reload: ${running[*]}"
  ((${#running[@]} == 0)) || printf '%s\n' "${running[0]}"
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

# Prints the repo an installed package came from; nothing when it is not installed (dnf exits 0 then).
installed_from_repo() { dnf repoquery --installed --qf '%{from_repo}\n' "$1"; }

ensure_pkg_from_repo() {
  local repo="$1"; shift
  local p
  for p in "$@"; do
    local from
    from="$(installed_from_repo "$p")" || die "dnf repoquery failed for $p"
    if [[ "$from" == "$repo" ]]; then log "$p already from $repo"; continue; fi
    log "installing $p from $repo"
    root dnf install -y --from-repo="$repo" "$p"
    from="$(installed_from_repo "$p")" || die "dnf repoquery failed for $p"
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

# A COPR is a third-party repo anyone can publish to, so its repo file is vekrona's own (etc/yum.repos.d/<key repo>.repo):
# the key comes from the pinned vendored file instead of the network, and includepkgs lets the repo offer only the
# packages vekrona takes from it. Adding a package to it is a deliberate edit of that file.
ensure_copr() {
  local c key_repo
  for c in "$@"; do
    key_repo="$(copr_key_repo "$c")"
    ensure_repo_key "$key_repo"
    # `dnf copr enable` writes this file under the same repo id, with the key's network URL and no package list.
    ensure_root_file_absent "/etc/yum.repos.d/_$(copr_id "$c").repo"
    ensure_root_file "$VEKRONA_ROOT/etc/yum.repos.d/$key_repo.repo" "/etc/yum.repos.d/$key_repo.repo"
    repo_enabled "$(copr_id "$c")" || die "copr not enabled: $c"
    log "copr enabled: $c"
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

# DST is read through root: its directory may be unreadable to the invoking user (/etc/polkit-1/rules.d is 750 root:polkitd).
root_file_current() {
  local src="$1" dst="$2" mode="$3" want
  root test -f "$dst" && root cmp -s "$src" "$dst" || return 1
  printf -v want '%o' "$((8#$mode))"
  [[ "$(root stat -c %a "$dst")" == "$want" ]]
}

ensure_root_file() {
  local src="$1" dst="$2" mode="${3:-0644}" tmp
  [[ -f "$src" ]] || die "source missing: $src"
  if root_file_current "$src" "$dst" "$mode"; then log "up to date: $dst"; return 0; fi
  log "installing: $dst"
  root install -d "$(dirname "$dst")"
  tmp="$(root mktemp "$dst.XXXXXX")"
  if ! { root install -m "$mode" "$src" "$tmp" && root mv -f "$tmp" "$dst"; }; then
    root rm -f "$tmp"
    die "install failed: $dst"
  fi
  root_file_current "$src" "$dst" "$mode" || die "content or mode mismatch after install: $dst"
}

# Installs a unit file from SRC into /etc/systemd/system under its own name and reloads systemd when that changed anything.
ensure_system_unit_file() {
  local src="$1" dst="${VEKRONA_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${1##*/}" changed=1
  if root_file_current "$src" "$dst" 0644; then changed=0; fi
  ensure_root_file "$src" "$dst"
  if [[ $changed -eq 1 ]]; then root systemctl daemon-reload; fi
}

# Installs the files NAME... from SRC_DIR into DST_DIR (drop-ins, or a sysconfig file) and, if any of them changed, makes
# systemd re-read its units and restarts UNIT if it runs. A daemon reads some settings only when it starts (a reload
# re-reads logind's IdleAction but never arms its idle timer), so a changed file would otherwise wait for a reboot.
ensure_dropins_restarting() {
  local unit="$1" src_dir="$2" dst_dir="$3" name before
  shift 3
  before="$(dropins_fingerprint "$dst_dir" "$@")"
  for name in "$@"; do
    ensure_root_file "$src_dir/$name" "$dst_dir/$name"
  done
  if [[ "$(dropins_fingerprint "$dst_dir" "$@")" != "$before" ]]; then
    log "$unit files changed: restarting $unit if it runs"
    root systemctl daemon-reload
    root systemctl try-restart "$unit"
  fi
}

# One line per drop-in NAME... in DIR: its checksum, or "absent".
dropins_fingerprint() {
  local dir="$1" name
  shift
  for name in "$@"; do
    if [[ -e "$dir/$name" ]]; then cksum <"$dir/$name"; else echo absent; fi
  done
}

# Installs a sudoers drop-in as root:root 0440 under its own name, but only once visudo accepts it. A broken drop-in
# locks the owner out of sudo, and so out of the repair: the candidate is checked under a name sudo ignores (it holds a
# dot) and moved into place only if it passes.
ensure_sudoers_dropin() {
  local src="$1" dst="/etc/sudoers.d/${1##*/}" tmp
  [[ -f "$src" ]] || die "source missing: $src"
  if root_file_current "$src" "$dst" 0440 && [[ "$(root stat -c %U:%G "$dst")" == root:root ]]; then
    log "up to date: $dst"
    return 0
  fi
  log "installing: $dst"
  tmp="$(root mktemp /etc/sudoers.d/.vekrona-candidate.XXXXXX)"
  if ! root install -m 0440 -o root -g root "$src" "$tmp"; then
    root rm -f "$tmp"
    die "install failed: $tmp"
  fi
  if ! root visudo -cf "$tmp"; then
    root rm -f "$tmp"
    die "visudo rejected $src: not installed, sudo is unchanged"
  fi
  root mv -f "$tmp" "$dst" || die "could not move the checked sudoers drop-in into place: $dst"
  root visudo -c || die "sudo configuration invalid after installing $dst: remove it with a root shell"
  root_file_current "$src" "$dst" 0440 || die "content or mode mismatch after install: $dst"
}

# Resolves "dnf ARGS..." with PROTECTED packages, prints the transaction and stores it in STORE instead of running it.
# Returns 1 when there is nothing to do; any other failure ends the command.
review_transaction() {
  local store="$1" protected="$2" out rc=0
  shift 2
  out="$(root dnf "$@" -y --store="$store" --setopt=protected_packages="$protected" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if [[ $rc -ne 0 ]]; then
    if [[ "$out" == *"protected packages"* ]]; then
      die "dnf $* refused: would remove protected packages ($(grep -o 'protected packages:.*' <<<"$out" | tr '\n' ' '))"
    fi
    die "dnf $* failed unexpectedly (exit $rc)"
  fi
  [[ "$out" != *"Nothing to do."* ]]
}

confirm() {
  local prompt="$1"
  [[ "${VEKRONA_YES:-0}" == "1" ]] && return 0
  local reply
  read -r -p "vekrona: $prompt [type yes] " reply < /dev/tty
  [[ "$reply" == "yes" ]]
}

# Reviews "dnf ARGS...", asks whether to proceed, then replays the stored transaction that was reviewed, so what a
# concurrent dnf or PackageKit run changed during the wait cannot change what is removed: dnf refuses to replay when the
# installed packages differ. Returns 1 only when there is nothing to do; a failed replay ends the command, so a caller
# that tests the result never mistakes it for "nothing to do". Arguments: where to keep the stores, the protected
# packages, what is being done, then dnf's arguments.
run_reviewed() {
  local store_root="$1" protected="$2" name="$3" store
  shift 3
  store="$(root mktemp -d -p "$store_root")"
  review_transaction "$store" "$protected" "$@" || return 1
  confirm "proceed with $name reviewed above?" || die "$name not confirmed"
  root dnf replay -y --setopt=protected_packages="$protected" "$store" || die "dnf replay of $name failed: nothing was applied"
}

# Installs the root-owned copy of the scripts that system units and root run: a unit cannot run from the 0700
# user_home_t home directory. Stage 40 installs it; stage 10 needs it before its akmods drop-ins run a script.
ensure_system_copy() {
  local script
  ensure_root_tree "$VEKRONA_ROOT/lib" "$VEKRONA_SYSTEM_DIR/lib"
  ensure_root_tree "$VEKRONA_ROOT/libexec" "$VEKRONA_SYSTEM_DIR/libexec"
  for script in "${VEKRONA_SYSTEM_BIN[@]}"; do
    ensure_root_file "$VEKRONA_ROOT/bin/$script" "$VEKRONA_SYSTEM_DIR/bin/$script" 0755
  done
  # lib/common.sh finds this repo file relative to its own checkout, which for the root-owned copy is VEKRONA_SYSTEM_DIR.
  ensure_root_file "$VEKRONA_ROOT/etc/yum.repos.d/1password.repo" "$VEKRONA_SYSTEM_DIR/etc/yum.repos.d/1password.repo"
  root_restorecon "$VEKRONA_SYSTEM_DIR"
}

# Gives a tree installed by root the SELinux labels policy assigns its path (on hosts that have SELinux tools).
root_restorecon() { if command -v restorecon >/dev/null; then root restorecon -R "$1"; fi; }

# True when DST holds exactly SRC's files (read as root); modes are not compared. __pycache__ is not part of a tree.
root_tree_matches() { root diff -r -x __pycache__ "$1" "$2" >/dev/null; }

# Mirrors directory SRC into the root-owned DST: directories 0755, files 0755 where SRC's is executable and 0644
# otherwise, and whatever SRC lacks is removed. SRC may hold only regular files and directories, with no newline in a name.
ensure_root_tree() {
  local src="$1" dst="$2" changed=0 rel kind target mode out
  local -A want_files=() want_dirs=()
  [[ -d "$src" ]] || die "source directory missing: $src"
  out="$(find "$src" -name __pycache__ -prune -o \( ! -type f ! -type d -o -name $'*\n*' \) -print)"
  [[ -z "$out" ]] || die "$src holds entries ensure_root_tree cannot mirror: $out"

  out="$(find "$src" -name __pycache__ -prune -o -type d -printf '%P\n')"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] || want_dirs[$rel]=1
    target="$dst${rel:+/$rel}"
    if root test -d "$target" && [[ "$(root stat -c %a "$target")" == 755 ]]; then continue; fi
    log "creating directory: $target"
    root install -d -m 0755 "$target"
    changed=1
  done <<<"$out"

  out="$(find "$src" -name __pycache__ -prune -o -type f -printf '%P\n')"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    want_files[$rel]=1
    if [[ -x "$src/$rel" ]]; then mode=0755; else mode=0644; fi
    root_file_current "$src/$rel" "$dst/$rel" "$mode" && continue
    ensure_root_file "$src/$rel" "$dst/$rel" "$mode"
    changed=1
  done <<<"$out"

  out="$(root find "$dst" -mindepth 1 -depth -printf '%y %P\n')"
  while IFS=' ' read -r kind rel; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" == d ]]; then
      [[ -z "${want_dirs[$rel]-}" ]] || continue
      log "removing directory: $dst/$rel"
      root rmdir "$dst/$rel"
    else
      [[ -z "${want_files[$rel]-}" ]] || continue
      log "removing: $dst/$rel"
      root rm -f "$dst/$rel"
    fi
    changed=1
  done <<<"$out"

  # Every run: an earlier run may have died between copying and labeling.
  root_restorecon "$dst"
  root_tree_matches "$src" "$dst" || die "$dst differs from $src after mirroring"
  if [[ $changed -eq 0 ]]; then log "up to date: $dst"; else log "mirrored: $src -> $dst"; fi
}

# grep -q on a file: 0 match, 1 no match; any other grep status (unreadable file, a directory) is an error, not "absent".
file_grep_q() {
  local status=0
  grep -q "$@" || status=$?
  [[ $status -le 1 ]] || die "grep -q $* failed with exit status $status"
  return "$status"
}

# grep that prints what it finds: matches or none both end with status 0; any other grep status (unreadable file, a
# directory) is an error, not "no match": it is reported, and inside $(...) the substitution fails.
file_grep() {
  local status=0
  grep "$@" || status=$?
  [[ $status -le 1 ]] || die "grep $* failed with exit status $status"
}

# write_file_atomic <path> <content>: replaces <path> in one rename, so a process watching or reading it never sees a
# truncated or half-written file. The parent directory must exist.
write_file_atomic() {
  local path="$1" content="$2" tmp
  tmp="$(dirname "$path")/.$(basename "$path").tmp.$$"
  if ! { printf '%s' "$content" > "$tmp" && mv -fT "$tmp" "$path"; }; then
    rm -f "$tmp"
    die "could not write $path"
  fi
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

# Every directory stage 50 links into, one per line (70-verify scans the same set).
vekrona_link_dirs() {
  local d
  printf '%s\n' \
    "$HOME/.config/sway" "$HOME/.config/environment.d" "$HOME/.config/xremap" "$HOME/.config/autostart" \
    "$HOME/.config/systemd/user" "$HOME/.config/fontconfig/conf.d" \
    "$HOME/.config/quickshell" \
    "$HOME/.local/share/fonts/vekrona" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/scalable/apps" "$HOME/.local/bin" \
    "$HOME/.config/scopebuddy" "$HOME/.config/MangoHud" "$HOME/.config/wireplumber" "$HOME/.config/pipewire" \
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
        enabled)  unit_is_active "$u" || root systemctl start "$u" ;;
        disabled) ! unit_is_active "$u" || root systemctl stop "$u" ;;
      esac
    fi
    log "unit $u: $state"
  done
}

# unit_state <var> is-active|is-enabled <unit> [systemctl flags]  Stores the state word systemctl prints. Both verbs
# print the state even when they exit non-zero (is-active: 3 inactive, 4 not found; is-enabled: 1 disabled, masked or
# linked, 4 not found; static, alias and indirect exit 0). Any other status, or output that is not one state word (an
# unreachable bus, for one), means systemctl itself failed. The caller's shell must run this, not a $(...) subshell,
# for the die to stop the install.
unit_state() {
  local var="$1" verb="$2" out rc=0
  shift 2
  out="$(systemctl "$verb" "$@")" || rc=$?
  case "$verb:$rc" in
    is-active:0 | is-active:3 | is-active:4 | is-enabled:0 | is-enabled:1 | is-enabled:4) ;;
    *) die "systemctl $verb $* failed with status $rc (its stderr is above)" ;;
  esac
  [[ -n "$out" && "$out" != *[[:space:]]* ]] || die "systemctl $verb $* printed no single unit state word (stdout: '$out'; its stderr is above)"
  printf -v "$var" %s "$out"
}

# unit_is_active|unit_is_enabled <unit> [systemctl flags, e.g. --user]
unit_is_active() { local state; unit_state state is-active "$@"; [[ "$state" == active ]]; }
unit_is_enabled() { local state; unit_state state is-enabled "$@"; [[ "$state" == enabled ]]; }

unit_matches_state() {
  local current
  unit_state current is-enabled "$1"
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
    if unit_is_active "$u"; then log "unit active: $u"; continue; fi
    root systemctl start "$u"
    unit_is_active "$u" || die "unit not active: $u"
  done
}

# Prints "UID NAME" for each logind session of a user on Wayland that is the active session of its seat. With "awake"
# only the sessions where somebody is at the keyboard: not locked and not idle.
wayland_sessions() {
  local awake="${1:-}" ids id props key value
  local -A session=()
  ids="$(loginctl list-sessions --no-legend | awk '{print $1}')"
  for id in $ids; do
    props="$(loginctl show-session "$id" -p Type -p Active -p LockedHint -p IdleHint -p Name -p User)"
    session=()
    while IFS='=' read -r key value; do session[$key]=$value; done <<<"$props"
    [[ "${session[Type]-}" == wayland && "${session[Active]-}" == yes ]] || continue
    if [[ "$awake" == awake ]]; then
      [[ "${session[LockedHint]-}" == no && "${session[IdleHint]-}" == no ]] || continue
    fi
    printf '%s %s\n' "${session[User]}" "${session[Name]}"
  done
}

# Runs a command as user NAME on that user's session bus, which a root unit has no environment for.
run_in_user_session() {
  local uid="$1" name="$2"
  shift 2
  runuser -u "$name" -- env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" "$@"
}

# Shows a desktop notification (notify-send arguments) to every user on a Wayland session. Returns 1, after logging it,
# when there is no such session: the caller decides whether that matters. A notification that fails is an error.
notify_user() {
  local sessions uid name
  sessions="$(wayland_sessions)"
  if [[ -z "$sessions" ]]; then
    log "no graphical session to notify: $*"
    return 1
  fi
  while read -r uid name; do
    run_in_user_session "$uid" "$name" notify-send -a vekrona "$@" || die "notify-send failed for $name"
  done <<<"$sessions"
}

# Asks user UID/NAME through vekrona-update-ask (its arguments follow) and prints the answer: an action key,
# "timeout" or "closed".
ask_user() {
  local uid="$1" name="$2"
  shift 2
  run_in_user_session "$uid" "$name" "$VEKRONA_SYSTEM_DIR/bin/vekrona-update-ask" "$@" || die "vekrona-update-ask failed for $name"
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
    if unit_is_enabled "$u" --user; then log "user unit enabled: $u"; continue; fi
    systemctl --user daemon-reload
    systemctl --user enable "$u"
    unit_is_enabled "$u" --user || die "user unit not enabled: $u"
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

# The Syncthing GUI and REST API listen on 127.0.0.1:8384, which every process of the machine can reach, so without a
# login any of them could reconfigure the daemon (add a shared folder, change its peers). Syncthing hashes the password
# before it stores it; vekrona keeps the clear text, once generated, in this file for the user to sign in with.
SYNCTHING_GUI_USER=vekrona
syncthing_gui_password_file() { printf '%s/syncthing-gui-password' "$(vekrona_state_dir)"; }

syncthing_config_file() {
  local paths
  paths="$(syncthing paths)" || die "syncthing paths failed"
  awk '/^Configuration file:/ { getline; sub(/^[ \t]+/, ""); print; exit }' <<<"$paths"
}

# Whether the daemon's config.xml demands a GUI login.
syncthing_gui_user_set() {
  local config gui
  config="$(syncthing_config_file)"
  [[ -f "$config" ]] || return 1
  gui="$(sed -n '/<gui[ >]/,/<\/gui>/p' "$config")"
  grep -q '<user>[^<][^<]*</user>' <<<"$gui"
}

# Sets a generated GUI login unless the config has one (a login the user set themselves stays). `syncthing generate`
# edits the config of a stopped daemon, which a running one would overwrite, so the daemon stops first; the caller starts it.
ensure_syncthing_gui_auth() {
  local pwfile password
  require_cmd syncthing python3
  pwfile="$(syncthing_gui_password_file)"
  if syncthing_gui_user_set; then log "syncthing GUI login already set"; return 0; fi
  password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')" || die "cannot generate a password"
  ensure_dir "$(dirname "$pwfile")"
  (umask 077 && write_file_atomic "$pwfile" "$password"$'\n')
  systemctl --user stop syncthing.service || die "cannot stop syncthing.service to set its GUI login"
  printf '%s\n' "$password" | syncthing generate --gui-user="$SYNCTHING_GUI_USER" --gui-password=- >/dev/null \
    || die "syncthing generate failed to set the GUI login"
  syncthing_gui_user_set || die "syncthing's config has no GUI login after generate"
  log "syncthing GUI login set: user $SYNCTHING_GUI_USER, password in $pwfile (print it with: cat $pwfile)"
}

user_in_group() {
  local user="$1" group="$2" groups
  groups="$(id -nG "$user")" || die "id -nG $user failed"
  [[ " $groups " == *" $group "* ]]
}

ensure_user_in_group() {
  local group="$1"
  getent group "$group" >/dev/null || die "group missing: $group"
  if user_in_group "$VEKRONA_USER" "$group"; then log "$VEKRONA_USER in $group"; return 0; fi
  log "adding $VEKRONA_USER to $group (re-login required)"
  root usermod -aG "$group" "$VEKRONA_USER"
  user_in_group "$VEKRONA_USER" "$group" || die "user not added to $group"
}

# The reverse: usermod has no remove option, gpasswd does. A group the user left stays in its running session until the next login.
ensure_user_not_in_group() {
  local group="$1"
  getent group "$group" >/dev/null || die "group missing: $group"
  if ! user_in_group "$VEKRONA_USER" "$group"; then log "$VEKRONA_USER not in $group"; return 0; fi
  log "removing $VEKRONA_USER from $group (re-login required)"
  root gpasswd -d "$VEKRONA_USER" "$group" >/dev/null
  ! user_in_group "$VEKRONA_USER" "$group" || die "user still in $group"
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

# irqbalance balances interrupts across cores for throughput; on a laptop that is battery spent for nothing.
irqbalance_wanted() { ! is_laptop; }

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
    *"is not enrolled"*) echo "Secure Boot is enabled and the akmods key $AKMODS_PUBLIC_KEY is not enrolled, so a module built by akmods would not load: disable Secure Boot or enroll the key (sudo mokutil --import $AKMODS_PUBLIC_KEY)" ;;
    *) echo "unexpected mokutil --test-key output ($enrolled), cannot verify the akmods key" ;;
  esac
}

die_if_secure_boot_blocks_akmods() {
  local problem
  problem="$(secure_boot_problem)"
  [[ -z "$problem" ]] || die "$problem"
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

# Dies listing the processes (PID and command) with their working directory, executable or an open file under $1.
# lsof +D is the exact check: fuser -m would report every process on the whole filesystem $1 lives on.
die_if_path_in_use() {
  local dir="$1" status=0 raw users
  require_cmd lsof
  raw="$(root lsof -w -F pc +D "$dir")" || status=$?
  ((status <= 1)) || die "lsof failed with status $status while checking whether $dir is in use"
  users="$(awk '/^p/ { pid = substr($0, 2) } /^c/ { print pid, substr($0, 2) }' <<<"$raw" | sort -u)"
  [[ -z "$users" ]] || die "$dir is in use by:"$'\n'"$users"
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

AKMODS_LOCK="${AKMODS_LOCK:-/run/akmods/akmods.lock}"
FLOCK_TIMEOUT_STATUS=1 # flock -w exits 1 on timeout, so any other status is a different failure

# Returns once no akmods build runs: waits for its process, then for the lock it holds, instead of queueing a redundant
# rebuild behind it.
wait_for_akmods_idle() {
  local lock_status=0
  wait_for_running_akmods
  root install -d -m 0755 "$(dirname "$AKMODS_LOCK")"
  root flock -w "$AKMODS_WAIT_SECONDS" "$AKMODS_LOCK" true || lock_status=$?
  case "$lock_status" in
    0) ;;
    "$FLOCK_TIMEOUT_STATUS") die "timed out after $AKMODS_WAIT_SECONDS s waiting for a running akmods build (lock $AKMODS_LOCK)" ;;
    *) die "flock on $AKMODS_LOCK failed with status $lock_status" ;;
  esac
}

# newest_akmods_failure_log <cache dir> <module> <kernel version>: the most recently written build log of a failed
# <module> build for that kernel. Each akmod version leaves its own log, so the newest one is the build that just failed.
# Prints nothing and returns 1 when there is none.
newest_akmods_failure_log() {
  local candidate newest=""
  for candidate in "$1/$2"/*-for-"$3".failed.log; do
    [[ -e "$candidate" ]] || continue
    if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then newest="$candidate"; fi
  done
  [[ -n "$newest" ]] || return 1
  printf '%s' "$newest"
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

# Runs "$@ DIR" with DIR a fresh directory only root can change (readable by everyone, so a check can run as the user), removed
# afterwards. Whatever root installs or runs after a check belongs here: a file in a user's scratch directory can be
# swapped by any process of that user between the check and its use.
with_root_scratch_dir() {
  (
    scratch="$(root mktemp -d)"
    trap 'root rm -rf "$scratch"' EXIT
    root chmod 0755 "$scratch"
    "$@" "$scratch"
  )
}

# root_owned_copy FILE DIR: copies FILE into the root-owned DIR (see with_root_scratch_dir) and prints the copy's path.
# Verify and use the copy, never FILE.
root_owned_copy() {
  local copy="$2/${1##*/}"
  root install -m 0644 -o root -g root "$1" "$copy" || die "cannot copy $1 into $2"
  printf '%s\n' "$copy"
}

# The one download chokepoint. Retries transient failures (DNS, connect, 5xx): redirectors such as
# mirrors.rpmfusion.org hand out a different mirror per request, so a retry usually lands on a healthy one.
download_file() {
  local url="$1" dest="$2"
  require_cmd curl
  curl --fail --silent --show-error --location --proto =https --proto-redir =https --globoff \
    --retry 5 --retry-all-errors --connect-timeout 20 \
    --output "$dest" "$url" || die "download failed: $url"
}

# The checksum of FILE (ALGORITHM is sha256 or sha512), as lowercase hex.
file_checksum() { "${1}sum" "$2" | awk '{print $1}'; }

# Dies unless the ALGORITHM checksum of FILE is SUM.
assert_checksum() {
  local algorithm="$1" sum="$2" file="$3" actual
  actual="$(file_checksum "$algorithm" "$file")"
  [[ "$actual" == "$sum" ]] || die "$algorithm mismatch for $file (expected $sum, got $actual)"
}

# The one verified-download chokepoint: fetches url and dies, leaving no file at dest, unless its checksum matches.
# algorithm is sha256 or sha512; sum is the lowercase hex digest published by the source.
fetch_verified() {
  local url="$1" algorithm="$2" sum="$3" dest="$4" actual
  case "$algorithm" in
    sha256 | sha512) ;;
    *) die "unsupported checksum algorithm for $url: $algorithm" ;;
  esac
  require_cmd "${algorithm}sum"
  log "fetching: $url"
  download_file "$url" "$dest"
  actual="$(file_checksum "$algorithm" "$dest")"
  [[ "$actual" == "$sum" ]] || { rm -f "$dest"; die "$algorithm mismatch for $url (expected $sum, got $actual)"; }
}

# A dangling symlink is still something on disk, so absent means neither a file nor a link.
path_absent() { [[ ! -e "$1" && ! -L "$1" ]]; }

ensure_root_file_absent() {
  local dst="$1"
  ! path_absent "$dst" || { log "absent: $dst"; return 0; }
  log "removing: $dst"
  root rm -f "$dst"
  path_absent "$dst" || die "failed to remove $dst"
}

# Removes a directory tree. Refuses a symlink or a file, so a link to somewhere else is never followed.
ensure_root_tree_absent() {
  local dst="$1"
  ! path_absent "$dst" || { log "absent: $dst"; return 0; }
  [[ ! -L "$dst" && -d "$dst" ]] || die "$dst is not a directory, resolve manually"
  log "removing: $dst"
  root rm -rf --one-file-system "$dst"
  path_absent "$dst" || die "failed to remove $dst"
}

owned_by() { [[ "$(stat -c '%U' "$1" 2>/dev/null)" == "$2" ]]; }
dir_mode_is() { [[ "$(stat -c '%a' "$1" 2>/dev/null)" == "$2" ]]; }

VEKRONA_REPO_KEY_DIR=/etc/pki/rpm-gpg

declare -A VEKRONA_REPO_KEY_FINGERPRINTS=(
  [1password]="3FEF9748469ADBE15DA7CA80AC2D62742012EA22"
  [copr-avengemedia-danklinux]="882B9F1C415EE16EBE149A0DFD1E0AB06C2E4F4A"
  [copr-blakegardner-xremap]="0614D53163910B889F874297D1BEC49C7B4D6A86"
  [copr-rossetnocpes-herdr]="AE7EDBCE7C2BDB5C784C4726AABC8F89407FB0C7"
  [copr-scottames-ghostty]="2DEFB319CCC3F393B6DAEAB297C83CA0FEB5DAFB"
  [cuda-fedora-44]="129994480EC63D2789BC98E490DFED2F73CD9B30"
  [protonvpn-fedora-44]="6929133BDE1CE1CFA9EDB286D84176F6844830D4"
  [rpmfusion-free-fedora-44]="E9A491A3DE247814E7E067EAE06F8ECDD651FF2E"
  [rpmfusion-nonfree-fedora-44]="79BDB88F9BBF73910FD4095B6A2AF96194843C65"
)

repo_key_name() { printf 'RPM-GPG-KEY-%s' "$1"; }

rpmfusion_key_repo() { printf 'rpmfusion-%s-fedora-%s' "$1" "$(rpm -E %fedora)"; }

# Proton signs each Fedora release's repo with its own key.
protonvpn_key_repo() { printf 'protonvpn-fedora-%s' "$(rpm -E %fedora)"; }

rpmfusion_release_url() {
  local section="$1"
  printf 'https://mirrors.rpmfusion.org/%s/fedora/rpmfusion-%s-release-%s.noarch.rpm' "$section" "$section" "$(rpm -E %fedora)"
}

rpmfusion_repo_file_uses_pinned_key() {
  local section="$1" lines
  lines="$(file_grep '^gpgkey=' "/etc/yum.repos.d/rpmfusion-$section.repo" | sort -u)"
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
  # rpm's default verification level (digest) accepts an RPM that carries no signature at all; "signature" makes a missing
  # or unverifiable one fail, and the scratch keyring holds only the pinned key.
  result="$(rpmkeys --dbpath "$keyring" --define '_pkgverify_level signature' --checksig -v "$rpm_file" 2>&1)" \
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
  ensure_root_file "$VEKRONA_ROOT/etc/yum.repos.d/1password.repo" "${VEKRONA_YUM_REPOS_DIR:-/etc/yum.repos.d}/1password.repo"
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

VEKRONA_UPDATE_LOCK="${VEKRONA_UPDATE_LOCK:-/run/vekrona-update.lock}"

# Holds the update lock until the process exits, so a check, an apply and a stage that changes the system's tools never
# run at the same time. The lock is read-only opened, so the installer can take it as a user; root creates the file.
update_lock() {
  require_cmd flock
  [[ -e "$VEKRONA_UPDATE_LOCK" ]] || root install -m 0644 /dev/null "$VEKRONA_UPDATE_LOCK"
  exec {VEKRONA_UPDATE_LOCK_FD}<"$VEKRONA_UPDATE_LOCK"
  if ! flock --nonblock "$VEKRONA_UPDATE_LOCK_FD"; then
    log "another update step holds $VEKRONA_UPDATE_LOCK, waiting for it"
    flock "$VEKRONA_UPDATE_LOCK_FD"
  fi
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

# Prints why the running nvidia module is not the one this install configured (reboot pending); nothing when it is.
# akmods' post-build modprobe can load the module before the modprobe options exist, so its version matching the one on
# disk is not enough: it must also have loaded after the options were last written. sysfs stamps /sys/module/nvidia
# when the module loads.
nvidia_reboot_reason() {
  local sys="${VEKRONA_SYSFS_ROOT:-}/sys/module/nvidia" conf="${VEKRONA_SYSFS_ROOT:-}$NVIDIA_MODPROBE_CONF" disk_version loaded_version
  [[ -e "$conf" ]] || die "missing $NVIDIA_MODPROBE_CONF"
  disk_version="$(modinfo -F version nvidia)" || die "nvidia module missing on disk"
  if [[ ! -e "$sys/version" ]]; then
    echo "the nvidia module is not loaded"
    return 0
  fi
  loaded_version="$(<"$sys/version")"
  if [[ "$disk_version" != "$loaded_version" ]]; then
    echo "loaded nvidia $loaded_version, on disk $disk_version"
  elif [[ "$conf" -nt "$sys" ]]; then
    echo "$NVIDIA_MODPROBE_CONF changed after the nvidia module loaded"
  fi
}

# True once the loaded nvidia module runs with NVreg_UseKernelSuspendNotifiers=0 (false while that is pending a reboot).
nvidia_suspend_notifiers_off() {
  local params="${VEKRONA_SYSFS_ROOT:-}/proc/driver/nvidia/params"
  [[ -e "$params" ]] && file_grep_q -x 'UseKernelSuspendNotifiers: 0' "$params"
}

# True when the initramfs is absent or older than the nvidia module or a config file that dracut bakes into it. Looks at
# file times only, never into the image.
initramfs_predates_nvidia_inputs() {
  local img module input
  img="$(initramfs_path "$1")"
  [[ -e "$img" ]] || return 0
  module="$(modinfo -k "$1" -n nvidia)" || die "nvidia module missing for $1"
  for input in "$module" "${VEKRONA_SYSFS_ROOT:-}$DRACUT_NVIDIA_CONF" "${VEKRONA_SYSFS_ROOT:-}$NVIDIA_MODPROBE_CONF"; do
    [[ "$img" -ot "$input" ]] && return 0
  done
  return 1
}

# True when the initramfs predates its inputs or lacks nvidia (a listing of the image).
initramfs_needs_nvidia_regen() {
  initramfs_predates_nvidia_inputs "$1" || ! initramfs_has_nvidia "$1"
}

# The units that build nvidia must redo the initramfs afterwards: akmods@<kver> (started by kernel-install's akmods
# hook) hands its kernel to vekrona-kernel-ready, which regenerates the initramfs and makes the kernel the GRUB default;
# akmods.service (at boot) regenerates the running kernel's initramfs.
akmods_dropin_active() {
  local name="$1" want unit
  case "$name" in
    akmods@*.service) want="ExecStartPost=$VEKRONA_SYSTEM_DIR/libexec/vekrona-kernel-ready %i" ;;
    akmods.service) want="ExecStartPost=$VEKRONA_SYSTEM_DIR/libexec/vekrona-nvidia-initramfs" ;;
    *) die "no initramfs drop-in is shipped for $name" ;;
  esac
  unit="$(systemctl cat "$name")" || die "cannot read unit $name"
  grep -qxF "$want" <<<"$unit"
}

# Builds the proprietary nvidia module for kernel $1 unless it exists; dies when the build fails or the module is wrong.
# akmods builds from scratch on every call. --force makes it retry a build that failed earlier (it ignores such a kernel
# otherwise, so one transient failure would block every retry). --rebuild is a `dnf reinstall`, which silently does
# nothing for a kmod that was never installed (an offline update skips the akmods hook), so only an installed kmod with
# the wrong module is rebuilt that way.
ensure_nvidia_module() {
  local kver="$1" problem akmods_args=(--force --kernels "$1")
  if [[ "$(nvidia_module_license "$kver")" == NVIDIA ]]; then
    log "ok: proprietary nvidia module already built for $kver"
  else
    if pkg_installed "kmod-nvidia-$kver"; then akmods_args=(--rebuild "${akmods_args[@]}"); fi
    log "building the proprietary nvidia module for $kver"
    root akmods "${akmods_args[@]}" || die "akmods failed for $kver; $NVIDIA_KERNEL_WAY_OUT"
  fi
  problem="$(nvidia_module_problem "$kver")"
  [[ -z "$problem" ]] || die "$problem; $NVIDIA_KERNEL_WAY_OUT"
  log "ok: nvidia module for $kver is proprietary (license NVIDIA)"
}

# Regenerates the initramfs of kernel $1 when it lacks nvidia or is stale; dies unless the image then carries nvidia and
# its options. One lsinitrd pass each, and callers that need the image verified (the default kernel) rely on this one.
# Under the kernel lock, so the check and the rebuild are one step against every other pass over the same image.
ensure_nvidia_initramfs() { with_kernel_lock ensure_nvidia_initramfs_locked "$1"; }

ensure_nvidia_initramfs_locked() {
  local kver="$1"
  if initramfs_needs_nvidia_regen "$kver"; then
    log "regenerating initramfs for $kver"
    dracut_locked -f --kver "$kver" || die "dracut failed for $kver; $NVIDIA_KERNEL_WAY_OUT"
    initramfs_has_nvidia "$kver" || die "initramfs for $kver still lacks nvidia after dracut; $NVIDIA_KERNEL_WAY_OUT"
  else
    log "ok: initramfs for $kver contains nvidia and is newer than the module and its config"
  fi
  initramfs_has_nvidia_options "$kver" || die "initramfs for $kver lacks $NVIDIA_MODPROBE_CONF; $NVIDIA_KERNEL_WAY_OUT"
}

# The boot-time pass (akmods.service, every boot) decides on file times alone: reading the 360 MB image costs seconds of
# disk and CPU on battery, and the boots where akmods built nothing are nearly all of them. Only an image older than
# what a build just wrote is regenerated, and then verified.
regenerate_nvidia_initramfs_if_older() {
  if initramfs_predates_nvidia_inputs "$1"; then
    ensure_nvidia_initramfs "$1"
  else
    log "ok: initramfs for $1 is newer than the nvidia module and its config"
  fi
}

NVIDIA_KERNEL_WAY_OUT="boot the previous kernel from the GRUB menu and look at /var/log/akmods/akmods.log"

# Prints the version of the kernel GRUB boots by default. With /boot as its own btrfs subvolume, grubby prints
# /boot/boot/vmlinuz-<version>, so only the file name counts.
default_kernel_version() {
  local path
  path="$(root grubby --default-kernel)" || die "grubby --default-kernel failed"
  [[ "$path" == */vmlinuz-* ]] || die "unexpected default kernel from grubby: '$path'"
  printf '%s' "${path##*/vmlinuz-}"
}

# True when the boot entry GRUB boots by default (saved_entry) still exists; removing the default kernel leaves it dangling.
# /boot/loader/entries is root-only (0700), so only root can tell an entry from a missing one.
default_boot_entry_exists() {
  local env saved
  env="$(root grub2-editenv list)" || die "grub2-editenv list failed"
  saved="$(sed -n 's/^saved_entry=//p' <<<"$env")"
  [[ -n "$saved" ]] || return 1
  root test -e "${VEKRONA_SYSFS_ROOT:-}/boot/loader/entries/$saved.conf"
}

default_kernel_initramfs_has_nvidia() {
  local kver
  kver="$(default_kernel_version)" || exit 1
  initramfs_has_nvidia "$kver"
}

# The one place that runs grubby --set-default (UPDATEDEFAULT=no keeps kernel-install from making a kernel the default).
set_default_kernel() {
  local current
  root grubby --set-default "/boot/vmlinuz-$1" || die "grubby --set-default failed for $1"
  current="$(default_kernel_version)" || die "cannot read the default kernel after setting it to $1"
  [[ "$current" == "$1" ]] || die "grubby did not make $1 the default kernel"
  log "ok: $1 is the GRUB default"
}

# Makes kernel $1 the GRUB default only when its module is proprietary and its initramfs carries nvidia and its options,
# because the machine has no other driver for its screen. Verifies by itself; dies otherwise, and the previous default stays.
promote_kernel_if_nvidia_ready() { with_kernel_lock promote_kernel_if_nvidia_ready_locked "$1"; }

promote_kernel_if_nvidia_ready_locked() {
  local kver="$1" why
  why="$(nvidia_module_problem "$kver")"
  if [[ -z "$why" ]] && ! initramfs_has_nvidia "$kver"; then why="its initramfs lacks nvidia"; fi
  if [[ -z "$why" ]] && ! initramfs_has_nvidia_options "$kver"; then why="its initramfs lacks $NVIDIA_MODPROBE_CONF"; fi
  [[ -z "$why" ]] || die "kernel $kver stays out of the GRUB default: $why; $NVIDIA_KERNEL_WAY_OUT"
  set_default_kernel "$kver"
}

VEKRONA_KERNEL_LOCK="${VEKRONA_KERNEL_LOCK:-/run/vekrona-kernel.lock}"
KERNEL_LOCK_WAIT_SECONDS="${KERNEL_LOCK_WAIT_SECONDS:-600}"

# Runs "$@" holding the kernel lock; "$@" may take it again (a pass that calls another locked pass). Every pass that
# rebuilds an initramfs or reads one to decide about the GRUB default takes it, and dracut_locked is the one place that
# runs dracut for the rest: the akmods@ drop-in (vekrona-kernel-ready, started by a dnf transaction with --no-block), an
# update's own pass over the newest kernel and the stages would otherwise run dracut on the same image at once. The
# update lock cannot serve: an update holds it for its whole run. A holder that never lets go fails the waiter after
# KERNEL_LOCK_WAIT_SECONDS instead of hanging boot-time akmods.service. Like update_lock, the file is opened read-only
# and created by root, so the installer can take the lock as a user.
with_kernel_lock() {
  local fd lock_status=0 status
  if [[ -n "${KERNEL_LOCK_HELD:-}" ]]; then "$@"; return; fi
  require_cmd flock
  [[ -e "$VEKRONA_KERNEL_LOCK" ]] || root install -m 0644 /dev/null "$VEKRONA_KERNEL_LOCK"
  exec {fd}<"$VEKRONA_KERNEL_LOCK" || die "cannot open $VEKRONA_KERNEL_LOCK"
  flock -w "$KERNEL_LOCK_WAIT_SECONDS" "$fd" || lock_status=$?
  case "$lock_status" in
    0) ;;
    "$FLOCK_TIMEOUT_STATUS") die "timed out after $KERNEL_LOCK_WAIT_SECONDS s waiting for the kernel lock $VEKRONA_KERNEL_LOCK (another initramfs pass is stuck?)" ;;
    *) die "flock on $VEKRONA_KERNEL_LOCK failed with status $lock_status" ;;
  esac
  KERNEL_LOCK_HELD=1
  # Not "$@" || status=$?: a command list would switch errexit off for everything "$@" runs. With errexit on, a failure
  # ends the shell here, which releases the lock too.
  "$@"
  status=$?
  KERNEL_LOCK_HELD=
  exec {fd}<&-
  return "$status"
}

# dracut for kernel versions, under the kernel lock: dracut_locked ARGS... runs `dracut ARGS...` as root.
dracut_locked() { with_kernel_lock root dracut "$@"; }

# ensure_nvidia_initramfs has verified the image, so the kernel can become the default without another lsinitrd pass.
ensure_nvidia_initramfs_then_default() {
  ensure_nvidia_initramfs "$1" && set_default_kernel "$1"
}

# Builds what kernel $1 needs to show the display, then makes it the GRUB default. Each step that fails dies by itself, naming
# the way out.
ensure_kernel_boots_with_nvidia() {
  local kver="$1"
  ensure_nvidia_module "$kver"
  with_kernel_lock ensure_nvidia_initramfs_then_default "$kver"
}

SYSCONFIG_KERNEL=/etc/sysconfig/kernel

# kernel-install makes every new kernel the GRUB default while UPDATEDEFAULT is yes (grub2-get-kernel-settings reads it
# from here for 20-grub.install).
kernel_updatedefault_is_no() {
  local file="${VEKRONA_SYSFS_ROOT:-}$SYSCONFIG_KERNEL"
  [[ -r "$file" ]] || die "cannot read $file"
  [[ "$(UPDATEDEFAULT=; . "$file"; printf '%s' "$UPDATEDEFAULT")" == no ]]
}

# New kernels stay out of the GRUB default until promote_kernel_if_nvidia_ready says they can show the display.
ensure_new_kernels_not_default() {
  local file="${VEKRONA_SYSFS_ROOT:-}$SYSCONFIG_KERNEL"
  if kernel_updatedefault_is_no; then log "ok: $SYSCONFIG_KERNEL has UPDATEDEFAULT=no"; return 0; fi
  log "setting UPDATEDEFAULT=no in $SYSCONFIG_KERNEL"
  if file_grep_q -E '^UPDATEDEFAULT=' "$file"; then
    root sed -i 's/^UPDATEDEFAULT=.*/UPDATEDEFAULT=no/' "$file"
  else
    # The file may lack a final newline, which the appended line would then join.
    { [[ -z "$(tail -c1 "$file")" ]] || echo; echo UPDATEDEFAULT=no; } | root tee -a "$file" >/dev/null
  fi
  kernel_updatedefault_is_no || die "UPDATEDEFAULT=no not applied to $SYSCONFIG_KERNEL"
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

session_started_by_gdm() { unit_is_active gdm; }

dm_unit_target() {
  local f=/etc/systemd/system/display-manager.service
  [[ -e "$f" ]] && basename "$(readlink -f "$f")"
}

dm_is_greetd() { [[ "$(dm_unit_target 2>/dev/null || true)" == greetd.service ]]; }

default_target_is_graphical() { [[ "$(systemctl get-default)" == graphical.target ]]; }

greetd_enabled() { unit_is_enabled greetd; }

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

# The pin name of a COPR's signing key (VEKRONA_REPO_KEY_FINGERPRINTS), and the stem of its key and repo file.
copr_key_repo() { echo "copr-${1/\//-}"; }

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
  geoclue2 geoclue2-libs gnome-keyring gnome-keyring-pam greetd grim gstreamer1-plugin-libav gstreamer1-plugin-openh264 gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly herdr inotify-tools intel-media-driver irqbalance
  jq kanshi khal
  libnotify mangohud mesa-va-drivers-freeworld mozilla-openh264 nix nix-daemon openh264 perl-interpreter pipewire pipewire-config-raop pipewire-pulseaudio pipewire-utils playerctl polkit
  proton-vpn-cli proton-vpn-gtk-app python3 python3-gobject python3-pyyaml python3-vdf qalculate qt6ct quickshell ripgrep rofi rsms-inter-fonts slurp steam swappy sway sway-config-fedora
  sway-systemd swayidle syncthing tailscale tuigreet tuned-ppd vdirsyncer wf-recorder wireplumber wl-clipboard wlr-randr wlsunset
  wpa_supplicant xdg-desktop-portal-gtk xdg-desktop-portal-wlr xdg-utils xremap-wlroots
  Thunar thunar-archive-plugin xarchiver imv pavucontrol google-noto-color-emoji-fonts
)

# shellcheck disable=SC2034
VEKRONA_RETIRED_PKGS=(dms dms-cli dgop danksearch matugen mise)

# What mise and the coding agents (Claude Code, Codex, OpenCode, Pi, Cursor) left behind; stage 30 removes them.
# /etc/claude-code/managed-settings.json stays: it is the login-method policy, installed by stage 40.
# shellcheck disable=SC2034
VEKRONA_RETIRED_AGENT_FILES=(/etc/yum.repos.d/mise.repo /etc/pki/rpm-gpg/RPM-GPG-KEY-mise /etc/profile.d/vekrona-mise.sh)
# shellcheck disable=SC2034
VEKRONA_RETIRED_MISE_SHARE=/usr/local/share/mise
# shellcheck disable=SC2034
VEKRONA_RETIRED_AGENT_TREES=(/etc/mise "$VEKRONA_RETIRED_MISE_SHARE" /etc/codex /etc/opencode)
# shellcheck disable=SC2034
VEKRONA_RETIRED_AGENT_LINKS=(/usr/local/bin/codex /usr/local/bin/pi /usr/local/bin/opencode /usr/local/bin/cursor-agent)
# shellcheck disable=SC2034
VEKRONA_RETIRED_MISE_REPO_ID=mise-repo
# shellcheck disable=SC2034
VEKRONA_RETIRED_MISE_KEY_FPR=24853EC9F655CE80B48E6C3A8B81C9D17413A06D

# True for a symlink whose stored target lies under mise's share; the target may already dangle, so plain readlink.
links_into_retired_mise_share() { [[ -L "$1" && "$(readlink "$1")" == "$VEKRONA_RETIRED_MISE_SHARE/"* ]]; }

# Fedora's crash reporter duplicates vekrona-error, which records every coredump from systemd-coredump, and its applet
# (abrt-gui) posts an "Oops!" card straight into the notification list instead of the errors panel.
# shellcheck disable=SC2034
VEKRONA_UNWANTED_PKGS=(abrt abrt-gui)

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

flatpak_remotes_system() {
  flatpak remotes --system --show-disabled --columns=name,options || die "flatpak remotes failed"
}

flatpak_remote_system_enabled() {
  local name="$1" remotes line
  remotes="$(flatpak_remotes_system)"
  line="$(awk -F'\t' -v n="$name" '$1==n' <<<"$remotes")"
  [[ -n "$line" ]] || return 1
  [[ "$line" != *disabled* ]]
}

flatpak_remote_system_exists() {
  local name="$1" remotes
  remotes="$(flatpak_remotes_system)"
  awk -F'\t' -v n="$name" '$1==n { found=1 } END { exit !found }' <<<"$remotes"
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
    spacing | border | size) [[ -z "$mode" ]] || die "vekrona_token_get $group $name: only color tokens have a mode, got '$mode'" ;;
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

WEBAPP_USER_JS_HEADER="// vekrona: generated by stage 50-user from config/firefox/webapp-user.js and the webapp's own user.js; edit those, not this file"

# Writes the webapp profile's user.js: the prefs every webapp shares, then the ones only this webapp needs (Spotify's DRM).
# An earlier install linked it into the checkout; that link is replaced. A user.js that vekrona did not generate is not touched.
ensure_webapp_user_js() {
  local appdir="$1" dst="$2" common="$VEKRONA_ROOT/config/firefox/webapp-user.js" content current
  [[ -f "$common" ]] || die "missing: $common"
  content="$WEBAPP_USER_JS_HEADER"$'\n'"$(<"$common")"
  if [[ -f "$appdir/user.js" ]]; then content+=$'\n'"$(<"$appdir/user.js")"; fi
  if [[ -f "$dst" && ! -L "$dst" ]]; then
    current="$(<"$dst")"
    [[ "${current%%$'\n'*}" == "$WEBAPP_USER_JS_HEADER" ]] || die "$dst was not generated by vekrona: move it away or merge it into config/firefox/webapp-user.js"
    if [[ "$current" == "$content" ]]; then log "current: $dst"; return 0; fi
  fi
  log "writing: $dst"
  write_file_atomic "$dst" "$content"$'\n'
}

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

require_btrfs_root() {
  local fs
  fs="$(findmnt -no FSTYPE /)" || die "could not determine the root filesystem type (findmnt failed)"
  [[ "$fs" == btrfs ]] || die "the root filesystem is ${fs:-unknown}, but vekrona needs btrfs (snapper snapshots of /, the /nix subvolume); reinstall Fedora with a btrfs root (the default layout)"
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
