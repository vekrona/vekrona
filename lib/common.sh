#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

VEKRONA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VEKRONA_ROOT
VEKRONA_USER="$(id -un)"

log()  { printf '\033[1;34m[vekrona]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[vekrona] WARN:\033[0m %s\n' "$*" >&2; }

report_error_for_die() {
  local msg="$1" bin="$VEKRONA_ROOT/bin/vekrona-error"
  [[ -x "$bin" ]] || return 0
  timeout 5 "$bin" report --title "$msg" --source vekrona >/dev/null 2>&1
}

die()  {
  printf '\033[1;31m[vekrona] FAIL:\033[0m %s\n' "$*" >&2
  report_error_for_die "$*" || warn "failed to report this error to vekrona-error"
  exit 1
}

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

mark_user_installed() {
  local installed=()
  local p
  for p in "$@"; do pkg_installed "$p" && installed+=("$p"); done
  [[ ${#installed[@]} -eq 0 ]] && { log "no installed packages to mark user among: $*"; return 0; }
  root dnf mark -y user "${installed[@]}"
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

user_gsettings() {
  local bus="/run/user/$(id -u)/bus"
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

ensure_symlink() {
  local src="$1" dst="$2"
  [[ -e "$src" ]] || die "symlink source missing: $src"
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

owned_by() { [[ "$(stat -c '%U' "$1" 2>/dev/null)" == "$2" ]]; }
dir_mode_is() { [[ "$(stat -c '%a' "$1" 2>/dev/null)" == "$2" ]]; }

gpg_key_fingerprint_file() {
  # --dry-run --show-only still needs a writable GNUPGHOME to open a keybox in, so use a scratch one
  # rather than the invoking user's own (possibly nonexistent) ~/.gnupg.
  local file="$1" gnupg_home fp
  gnupg_home="$(mktemp -d)"
  fp="$(gpg --homedir "$gnupg_home" --batch --with-colons --import-options show-only --dry-run --import "$file" 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
  rm -rf "$gnupg_home"
  printf '%s' "$fp"
}

gpg_pubkey_installed() {
  # rpm on this Fedora release stores a gpg-pubkey package's full lowercase fingerprint as %{VERSION},
  # not the classic 8-hex short key id, so that is what this checks against.
  local fingerprint_lower="$1"
  rpm -q gpg-pubkey --qf '%{VERSION}\n' 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx "$fingerprint_lower"
}

ensure_gpg_key_imported() {
  local url="$1" fingerprint="$2" fingerprint_lower got tmp
  ensure_pkg gnupg2
  fingerprint_lower="$(tr '[:upper:]' '[:lower:]' <<<"$fingerprint")"
  gpg_pubkey_installed "$fingerprint_lower" && { log "gpg key already imported: $fingerprint"; return 0; }
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp" || die "failed to download gpg key: $url"
  # Fingerprint the exact bytes we are about to import, not a second, separate download of the same URL.
  got="$(gpg_key_fingerprint_file "$tmp")"
  [[ -n "$got" ]] || { rm -f "$tmp"; die "could not determine gpg key fingerprint: $url"; }
  [[ "$got" == "$fingerprint" ]] || { rm -f "$tmp"; die "gpg key fingerprint mismatch for $url: got $got, expected $fingerprint"; }
  log "importing gpg key: $url"
  root rpm --import "$tmp"
  rm -f "$tmp"
  gpg_pubkey_installed "$fingerprint_lower" || die "gpg key not imported: $fingerprint"
}

# shellcheck disable=SC2034
CLAUDE_CODE_REPO_ID="claude-code"
# shellcheck disable=SC2034
CLAUDE_CODE_GPG_URL="https://downloads.claude.ai/keys/claude-code.asc"
# shellcheck disable=SC2034
CLAUDE_CODE_GPG_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

# shellcheck disable=SC2034
MISE_REPO_ID="mise-repo"
# shellcheck disable=SC2034
MISE_GPG_URL="https://mise.jdx.dev/gpg-key.pub"
# shellcheck disable=SC2034
MISE_GPG_FINGERPRINT="24853EC9F655CE80B48E6C3A8B81C9D17413A06D"

# shellcheck disable=SC2034
VEKRONA_AGENT_PKGS=(claude-code mise nodejs22-npm)
# shellcheck disable=SC2034
VEKRONA_AGENT_TOOLS=(codex pi opencode cursor-agent)

MISE_SYSTEM_DATA_DIR=/usr/local/share/mise
MISE_SYSTEM_CONFIG_DIR=/etc/mise
MISE_SYSTEM_CACHE_DIR=/usr/local/share/mise/cache
MISE_SYSTEM_STATE_DIR=/usr/local/share/mise/state

mise_system() {
  # mise --system only installs binary-download backends; overriding MISE_DATA_DIR/MISE_CONFIG_DIR
  # instead runs the normal (non-system) code path against root-owned dirs, which also covers our npm/aqua/http tools.
  # sudo resets HOME to /root; pin HOME and every cache path so npm/mise never write outside this tree.
  root env \
    HOME="$MISE_SYSTEM_DATA_DIR" \
    MISE_DATA_DIR="$MISE_SYSTEM_DATA_DIR" \
    MISE_CONFIG_DIR="$MISE_SYSTEM_CONFIG_DIR" \
    MISE_CACHE_DIR="$MISE_SYSTEM_CACHE_DIR" \
    MISE_STATE_DIR="$MISE_SYSTEM_STATE_DIR" \
    npm_config_cache="$MISE_SYSTEM_DATA_DIR/npm-cache" \
    mise "$@"
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
  root grubby --info=ALL | awk -v a="$arg" '
    /^args=/ { n=split($0, w, /[ "]/); for (i=1;i<=n;i++) if (w[i]==a) found=1 }
    END { exit !found }
  '
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
  grep -qE -- "$pattern" "$file" || die "$file does not match: $pattern"
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

dms_changelog_version() {
  local qml=/usr/share/quickshell/dms/Services/ChangelogService.qml v
  v="$(grep -oP 'currentVersion:\s*"\K[^"]+' "$qml")" || die "cannot read DMS changelog version from $qml"
  printf '%s' "$v"
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

VEKRONA_DESKTOP_PKGS=(
  NetworkManager NetworkManager-wifi accountsservice atkinson-hyperlegible-next-fonts bluez brightnessctl
  danksearch dconf dgop dms firefox flatpak gamemode gamescope ghostty
  gnome-keyring gnome-keyring-pam greetd grim inotify-tools
  jetbrains-mono-fonts jq kanshi
  libnotify mangohud matugen perl-interpreter pipewire pipewire-pulseaudio playerctl polkit
  python3 python3-gobject python3-pyyaml quickshell rofi rsms-inter-fonts slurp steam swappy sway
  sway-config-fedora sway-systemd tuigreet tuned-ppd wf-recorder wireplumber wl-clipboard wlr-randr
  wpa_supplicant xdg-desktop-portal-gtk xdg-desktop-portal-wlr xremap-wlroots
)

vekrona_desktop_pkgs() {
  local wlroots_pkg
  wlroots_pkg="$(wlroots_package_name)"
  printf '%s\n' "${VEKRONA_DESKTOP_PKGS[@]}" "$wlroots_pkg"
}

VEKRONA_VERSIONLOCK_PKGS=(sway dms quickshell qt6-qtbase qt6-qtdeclarative qt6-qtwayland xremap-wlroots)

vekrona_versionlock_pkgs() {
  local wlroots_pkg
  wlroots_pkg="$(wlroots_package_name)"
  printf '%s\n' "${VEKRONA_VERSIONLOCK_PKGS[@]}" "$wlroots_pkg"
}

flatpak_installed() {
  flatpak list --app --columns=application 2>/dev/null | grep -qx "$1"
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

declare -A GHOSTTY_THEME_MAP=(
  [tokyo-night]="TokyoNight"
  [nord]="Nord"
  [gruvbox-dark]="Gruvbox Dark"
  [catppuccin-mocha]="Catppuccin Mocha"
)

GHOSTTY_THEME_INCLUDE="$HOME/.config/ghostty/vekrona-theme"

ghostty_theme_for() {
  local name="$1"
  [[ -n "${GHOSTTY_THEME_MAP[$name]+x}" ]] || die "no Ghostty built-in theme mapped for vekrona theme: $name"
  printf '%s' "${GHOSTTY_THEME_MAP[$name]}"
}

write_ghostty_theme_include() {
  local vekrona_name="$1" ghostty_name include_dir tmp
  ghostty_name="$(ghostty_theme_for "$vekrona_name")"
  include_dir="$(dirname "$GHOSTTY_THEME_INCLUDE")"
  ensure_dir "$include_dir"
  tmp="$(mktemp "$include_dir/.$(basename "$GHOSTTY_THEME_INCLUDE").XXXXXX")"
  printf 'theme = %s\n' "$ghostty_name" > "$tmp"
  mv "$tmp" "$GHOSTTY_THEME_INCLUDE"
}

vekrona_state_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/vekrona"; }
vekrona_theme_name_file() { printf '%s' "$(vekrona_state_dir)/theme"; }
vekrona_active_theme_file() { printf '%s' "$(vekrona_state_dir)/active-theme.json"; }

firefox_profile_root() {
  if [[ -d "$HOME/.mozilla/firefox" ]]; then
    printf '%s' "$HOME/.mozilla/firefox"
  else
    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
  fi
}
