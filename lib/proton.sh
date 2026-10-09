#!/usr/bin/env bash
# Proton's desktop apps ship as unsigned vendor RPMs listed in JSON feeds. bin/vekrona-proton turns the feeds
# into a local dnf repo; docs/updates.md explains the trust model.

VEKRONA_PROTON_REPO_DIR="${VEKRONA_PROTON_REPO_DIR:-/var/lib/vekrona/proton-repo}"
VEKRONA_PROTON_URL_PREFIX=https://proton.me/download/

# RPM name -> feed URL
declare -A VEKRONA_PROTON_FEEDS=(
  [proton-mail]="https://proton.me/download/mail/linux/version.json"
  [proton-pass]="https://proton.me/download/PassDesktop/linux/x64/version.json"
  [proton-authenticator]="https://proton.me/download/authenticator/linux/version.json"
)

proton_package_names() { printf '%s\n' "${!VEKRONA_PROTON_FEEDS[@]}" | sort; }

# jq definition shared by the picks below: the Stable releases rolled out to everyone. The rollout field is
# RolloutProportion in the Mail feed and RolloutPercentage in the Pass and Authenticator feeds; both run from 0 to 1.
PROTON_JQ_DEFS='def everywhere: .CategoryName == "Stable" and ((.RolloutProportion // .RolloutPercentage) == 1);'

# Prints "version url sha512" for the newest Stable release rolled out to everyone that has an RPM.
proton_feed_pick() {
  local feed="$1" version picked url sum
  require_cmd jq sort
  version="$(jq -r "$PROTON_JQ_DEFS"' .Releases[] | select(everywhere) | .Version' "$feed" | sort -V | tail -n 1)" \
    || die "cannot read Proton feed $feed"
  [[ -n "$version" ]] || die "no Stable release rolled out to everyone in Proton feed $feed"
  picked="$(jq -r --arg version "$version" "$PROTON_JQ_DEFS"'
    first(.Releases[] | select(everywhere and .Version == $version))
    | first((.File // [])[] | select(.Identifier | startswith(".rpm")))
    | "\(.Url) \(.Sha512CheckSum)"' "$feed")" || die "cannot read Proton feed $feed"
  [[ -n "$picked" ]] || die "Proton release $version in $feed has no .rpm file"
  read -r url sum <<<"$picked"
  [[ "$url" == "$VEKRONA_PROTON_URL_PREFIX"* ]] || die "Proton release $version in $feed points outside $VEKRONA_PROTON_URL_PREFIX: $url"
  [[ "$sum" =~ ^[0-9a-f]{128}$ ]] || die "Proton release $version in $feed has no valid sha512: '$sum'"
  printf '%s %s %s\n' "$version" "$url" "$sum"
}

# Downloads the feed of one package into scratch_dir and prints "version url sha512" of its latest release.
proton_latest() {
  local name="$1" scratch_dir="$2" feed
  feed="$scratch_dir/$name.json"
  download_file "${VEKRONA_PROTON_FEEDS[$name]}" "$feed"
  proton_feed_pick "$feed"
}

# Prints the installed version of an RPM, or "-" when it is not installed.
proton_installed_version() {
  if pkg_installed "$1"; then rpm -q --qf '%{VERSION}\n' "$1"; else printf -- '-\n'; fi
}

# True when feed version a is newer than installed version b ("-" means not installed).
proton_version_newer() {
  local a="$1" b="$2"
  [[ "$b" == "-" ]] && return 0
  [[ "$a" != "$b" && "$(printf '%s\n' "$a" "$b" | sort -V | tail -n 1)" == "$a" ]]
}
