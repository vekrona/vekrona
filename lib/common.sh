#!/usr/bin/env bash
set -euo pipefail

VEKRONA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VEKRONA_ROOT
VEKRONA_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/vekrona"
VEKRONA_USER="${SUDO_USER:-$USER}"

log()  { printf '\033[1;34m[vekrona]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[vekrona] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[vekrona] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

sudo_refresh() {
  [[ $EUID -eq 0 ]] && return 0
  sudo -v || die "sudo credentials required"
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

ensure_pkg_absent() {
  local present=()
  local p
  for p in "$@"; do pkg_installed "$p" && present+=("$p"); done
  [[ ${#present[@]} -eq 0 ]] && return 0
  log "removing: ${present[*]}"
  root dnf remove -y "${present[@]}"
  for p in "${present[@]}"; do pkg_installed "$p" && die "package still installed: $p"; done
}

repo_enabled() { dnf repolist --enabled 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

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
    local id="copr:copr.fedorainfracloud.org:${c/\//:}"
    repo_enabled "$id" && { log "copr enabled: $c"; continue; }
    log "enabling copr: $c"
    root dnf copr enable -y "$c"
    repo_enabled "$id" || die "copr not enabled: $c"
  done
}

ensure_copr_absent() {
  local c
  for c in "$@"; do
    local id="copr:copr.fedorainfracloud.org:${c/\//:}"
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

ensure_line() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then log "line present in $file: $line"; return 0; fi
  log "appending to $file: $line"
  printf '%s\n' "$line" | root tee -a "$file" >/dev/null
  grep -qxF -- "$line" "$file" || die "line not written to $file"
}

ensure_symlink() {
  local src="$1" dst="$2"
  [[ -e "$src" ]] || die "symlink source missing: $src"
  if [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]]; then log "linked: $dst"; return 0; fi
  if [[ -e "$dst" && ! -L "$dst" ]]; then
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

ensure_symlink_tree() {
  local srcdir="$1" dstdir="$2"
  [[ -d "$srcdir" ]] || die "directory missing: $srcdir"
  local f
  while IFS= read -r -d '' f; do
    ensure_symlink "$f" "$dstdir/${f#"$srcdir"/}"
  done < <(find "$srcdir" -type f -print0)
}

ensure_dir() {
  local d
  for d in "$@"; do [[ -d "$d" ]] || mkdir -p "$d"; done
}

ensure_system_unit() {
  local state="$1"; shift
  local u
  for u in "$@"; do
    if [[ "$(systemctl is-enabled "$u" 2>/dev/null || true)" == "$state" ]]; then log "unit $u: $state"; continue; fi
    case "$state" in
      enabled)  root systemctl enable "$u" ;;
      disabled) root systemctl disable "$u" ;;
      *) die "unknown unit state: $state" ;;
    esac
    [[ "$(systemctl is-enabled "$u" 2>/dev/null || true)" == "$state" ]] || die "unit $u not $state"
  done
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

ensure_user_in_group() {
  local group="$1"
  getent group "$group" >/dev/null || die "group missing: $group"
  if id -nG "$VEKRONA_USER" | tr ' ' '\n' | grep -qx "$group"; then log "$VEKRONA_USER in $group"; return 0; fi
  log "adding $VEKRONA_USER to $group (re-login required)"
  root usermod -aG "$group" "$VEKRONA_USER"
  getent group "$group" | grep -q "\b$VEKRONA_USER\b" || die "user not added to $group"
}

VERSIONLOCK_FILE=/etc/dnf/versionlock.toml

versionlock_has() { grep -qE "^name = \"$1\"" "$VERSIONLOCK_FILE" 2>/dev/null; }

versionlock_evrs() { grep -E '^value = ' "$VERSIONLOCK_FILE" 2>/dev/null | sed -E 's/^value = "(.*)"$/\1/'; }

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

kernel_cmdline_has() { grep -qw -- "$1" /proc/cmdline; }

grubby_has_arg() {
  local arg="$1"
  root grubby --info=ALL | grep '^args=' | grep -qw -- "$arg"
}

ensure_kernel_arg() {
  local arg
  for arg in "$@"; do
    if grubby_has_arg "$arg" && grep -qw -- "$arg" /etc/kernel/cmdline 2>/dev/null; then log "kernel arg present: $arg"; continue; fi
    log "adding kernel arg: $arg"
    root grubby --update-kernel=ALL --args="$arg"
    grubby_has_arg "$arg" || die "kernel arg not applied by grubby: $arg"
    grep -qw -- "$arg" /etc/kernel/cmdline || die "kernel arg not in /etc/kernel/cmdline: $arg"
  done
}

session_is_sway() { [[ "${XDG_CURRENT_DESKTOP:-}" == "sway" ]]; }

session_started_by_gdm() { [[ "$(systemctl is-active gdm 2>/dev/null || true)" == "active" ]]; }

assert() {
  local msg="$1"; shift
  if "$@"; then log "ok: $msg"; else die "assertion failed: $msg"; fi
}

assert_file_contains() {
  local file="$1" pattern="$2"
  grep -qE -- "$pattern" "$file" || die "$file does not match: $pattern"
  log "ok: $file matches $pattern"
}

stage_stamp() {
  ensure_dir "$VEKRONA_STATE"
  date -Is > "$VEKRONA_STATE/$1.done"
}
