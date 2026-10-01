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

ensure_pkg_swapped() {
  local from="$1" to="$2"
  if pkg_installed "$to" && ! pkg_installed "$from"; then log "already swapped: $from -> $to"; return 0; fi
  if ! pkg_installed "$from"; then
    ensure_pkg "$to"
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

ensure_line() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then log "line present in $file: $line"; return 0; fi
  log "appending to $file: $line"
  printf '%s\n' "$line" | root tee -a "$file" >/dev/null
  grep -qxF -- "$line" "$file" || die "line not written to $file"
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

ensure_system_unit_active() {
  local u
  for u in "$@"; do
    if [[ "$(systemctl is-active "$u" 2>/dev/null || true)" == active ]]; then log "unit active: $u"; continue; fi
    root systemctl start "$u"
    [[ "$(systemctl is-active "$u" 2>/dev/null || true)" == active ]] || die "unit not active: $u"
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

VEKRONA_REPO_KEY_DIR=/etc/pki/rpm-gpg

# shellcheck disable=SC2034
CLAUDE_CODE_REPO_ID="claude-code"
# shellcheck disable=SC2034
MISE_REPO_ID="mise-repo"

declare -A VEKRONA_REPO_KEY_FINGERPRINTS=(
  [claude-code]="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
  [mise]="24853EC9F655CE80B48E6C3A8B81C9D17413A06D"
  [1password]="3FEF9748469ADBE15DA7CA80AC2D62742012EA22"
)

repo_key_name() { printf 'RPM-GPG-KEY-%s' "$1"; }

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
  [[ -v "VEKRONA_REPO_KEY_FINGERPRINTS[$repo]" ]] || die "no pinned gpg key fingerprint for repo: $repo"
  local expected="${VEKRONA_REPO_KEY_FINGERPRINTS[$repo]}"
  found="$(key_file_primary_fingerprints "$file")"
  [[ "$found" == "$expected" ]] || die "gpg key file for repo '$repo' ($file) must hold exactly one primary key with fingerprint $expected, found: ${found//$'\n'/ }; if the vendor rotated its key, verify the new fingerprint out of band, then update VEKRONA_REPO_KEY_FINGERPRINTS and etc/pki/rpm-gpg/$(repo_key_name "$repo") together"
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

ensure_repo_key() {
  local repo="$1" src dst
  ensure_pkg gnupg2
  src="$VEKRONA_ROOT/etc/pki/rpm-gpg/$(repo_key_name "$repo")"
  dst="$VEKRONA_REPO_KEY_DIR/$(repo_key_name "$repo")"
  assert_repo_key_file_pinned "$repo" "$src"
  ensure_root_file "$src" "$dst"
  assert_repo_key_file_pinned "$repo" "$dst"
  if repo_key_in_rpm_keyring "$repo"; then
    log "gpg key already imported for repo $repo"
  else
    log "importing gpg key for repo $repo"
    root rpm --import "$dst"
  fi
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

# shellcheck disable=SC2034
VEKRONA_COPRS=(blakegardner/xremap scottames/ghostty avengemedia/dms avengemedia/danklinux rossetnocpes/herdr)

copr_id() { echo "copr:copr.fedorainfracloud.org:${1/\//:}"; }

# shellcheck disable=SC2034
VEKRONA_X11_FLATPAKS=(com.discordapp.Discord md.obsidian.Obsidian org.signal.Signal)

# shellcheck disable=SC2034
declare -A VEKRONA_PINNED_PKGS=(
  [quickshell]="$(copr_id avengemedia/danklinux)"
  [herdr]="$(copr_id rossetnocpes/herdr)"
)

VEKRONA_DESKTOP_PKGS=(
  1password 1password-cli NetworkManager NetworkManager-wifi accountsservice atkinson-hyperlegible-next-fonts bluez brightnessctl btop
  danksearch dconf dgop dms ffmpeg firefox flatpak gamemode gamescope ghostty
  gnome-keyring gnome-keyring-pam greetd grim gstreamer1-plugin-libav gstreamer1-plugin-openh264 gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly herdr inotify-tools intel-media-driver
  jetbrains-mono-fonts jq kanshi
  libnotify mangohud matugen mesa-va-drivers-freeworld mozilla-openh264 nix nix-daemon openh264 perl-interpreter pipewire pipewire-pulseaudio playerctl polkit
  python3 python3-gobject python3-pyyaml python3-vdf quickshell rofi rsms-inter-fonts slurp steam swappy sway sway-config-fedora
  sway-systemd tailscale tuigreet tuned-ppd wf-recorder wireplumber wl-clipboard wlr-randr
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
