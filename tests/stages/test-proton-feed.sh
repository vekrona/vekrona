#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
source "$REPO/tests/lib.sh"
source "$REPO/lib/proton.sh"

FIXTURES="$REPO/tests/fixtures/proton"
SUM="$(printf 'a%.0s' {1..128})"
RPM_URL="https://proton.me/download/app/%s.rpm"

# release CATEGORY VERSION ROLLOUT_FIELD ROLLOUT [RPM_URL [RPM_SUM]]: one feed release carrying a deb and an rpm.
release() {
  local category="$1" version="$2" field="$3" rollout="$4"
  local url="${5:-$(printf "$RPM_URL" "$version")}" sum="${6:-$SUM}"
  jq -n --arg category "$category" --arg version "$version" --arg field "$field" --argjson rollout "$rollout" \
    --arg url "$url" --arg sum "$sum" \
    '{CategoryName: $category, Version: $version, ($field): $rollout,
      File: [{Identifier: ".deb (Ubuntu/Debian)", Url: "https://proton.me/download/app/x.deb", Sha512CheckSum: $sum},
             {Identifier: ".rpm (Fedora/RHEL)", Url: $url, Sha512CheckSum: $sum}]}'
}

# feed NAME RELEASE...: writes $work/NAME.json and prints its path.
feed() {
  local name="$1"; shift
  if (($# > 0)); then printf '%s\n' "$@" | jq -s '{Releases: .}' > "$work/$name.json"; else echo '{"Releases": []}' > "$work/$name.json"; fi
  echo "$work/$name.json"
}

picks() { [[ "$(proton_feed_pick "$1")" == "$2" ]] || die "proton_feed_pick $1 gave: $(proton_feed_pick "$1"); wanted: $2"; }

dies_with() {
  local expected="$1" file="$2" out
  out="$(proton_feed_pick "$file" 2>&1)" && die "proton_feed_pick accepted $file: $out"
  [[ "$out" == *"$expected"* ]] || die "error for $file lacks '$expected': $out"
}

picks "$FIXTURES/mail.json" "1.14.0 https://proton.me/download/mail/linux/1.14.0/ProtonMail-desktop-beta.rpm 0b4ba742b86754bf2a85672096eeca0baa14799044ba4129c2d96668db8a111bd8ad3bc0769ace711e505bde3712251a4933fb0c5702dffe9a32193918f476be"
log "ok: the Mail feed gives its newest Stable rpm, not the EarlyAccess or Alpha builds"

picks "$FIXTURES/pass.json" "1.40.2 https://proton.me/download/pass/linux/proton-pass-1.40.2-1.x86_64.rpm $(jq -r '.Releases[] | select(.Version == "1.40.2") | .File[] | select(.Identifier | startswith(".rpm")) | .Sha512CheckSum' "$FIXTURES/pass.json")"
log "ok: the Pass feed (RolloutPercentage) skips the half-rolled-out Stable 1.42.0 and the Beta 1.41.0"

picks "$FIXTURES/authenticator.json" "1.1.6 https://proton.me/download/authenticator/linux/ProtonAuthenticator-1.1.6-1.x86_64.rpm $(jq -r '.Releases[0].File[] | select(.Identifier | startswith(".rpm")) | .Sha512CheckSum' "$FIXTURES/authenticator.json")"
log "ok: the Authenticator feed gives its newest fully rolled-out Stable rpm"

picks "$(feed ordering "$(release Stable 1.9.0 RolloutProportion 1)" "$(release Stable 1.10.0 RolloutProportion 1)" "$(release Stable 1.2.0 RolloutProportion 1)")" \
  "1.10.0 https://proton.me/download/app/1.10.0.rpm $SUM"
log "ok: versions order numerically, 1.10.0 is newer than 1.9.0"

picks "$(feed rollout "$(release Stable 2.0.0 RolloutProportion 0.5)" "$(release Stable 1.0.0 RolloutProportion 1)")" \
  "1.0.0 https://proton.me/download/app/1.0.0.rpm $SUM"
log "ok: a release rolled out to half the users is skipped"

dies_with "no Stable release" "$(feed all-partial "$(release Stable 2.0.0 RolloutPercentage 0.5)" "$(release Stable 1.0.0 RolloutPercentage 0)")"
log "ok: dies when no Stable release is rolled out to everyone"

dies_with "no Stable release" "$(feed no-stable "$(release EarlyAccess 2.0.0 RolloutProportion 1)" "$(release Alpha 1.0.0 RolloutProportion 1)" "$(release Beta 1.0.0 RolloutPercentage 1)")"
log "ok: dies when only non-Stable channels exist"

dies_with "no Stable release" "$(feed empty)"
log "ok: dies on empty Releases"

dies_with "no .rpm file" "$(feed no-rpm "$(release Stable 1.0.0 RolloutProportion 1 | jq '.File |= map(select(.Identifier | startswith(".rpm") | not))')")"
log "ok: dies when the newest Stable release has no rpm, rather than falling back to an older one"

dies_with "points outside" "$(feed elsewhere "$(release Stable 1.0.0 RolloutProportion 1 https://example.invalid/download/x.rpm)")"
dies_with "points outside" "$(feed lookalike "$(release Stable 1.0.0 RolloutProportion 1 https://proton.me.example.invalid/download/x.rpm)")"
dies_with "points outside" "$(feed plain-http "$(release Stable 1.0.0 RolloutProportion 1 http://proton.me/download/x.rpm)")"
log "ok: dies on an rpm URL outside https://proton.me/download/"

for url in https://proton.me/download/../evil/x.rpm https://proton.me/download/a/%2e%2e/x.rpm 'https://proton.me/download/{a,b}.rpm' \
  'https://proton.me/download/x.rpm?a=b' 'https://proton.me/download/'; do
  dies_with "points outside" "$(feed "tricky-url" "$(release Stable 1.0.0 RolloutProportion 1 "$url")")"
done
log "ok: dies on an rpm URL that climbs out of the prefix or carries characters curl or the shell would interpret"

for version in ../../etc/x '1.0/../x' '-rf' 'v1.0' '1.0 2.0' '1.0;x'; do
  dies_with "is not a version" "$(feed "tricky-version" "$(release Stable "$version" RolloutProportion 1)")"
done
log "ok: dies on a feed version that is not a plain version, since it becomes part of a file name"

dies_with "no valid sha512" "$(feed short-sum "$(release Stable 1.0.0 RolloutProportion 1 "" abc)")"
log "ok: dies on a missing or malformed sha512"

echo '{"Releases": [' > "$work/malformed.json"
dies_with "cannot read Proton feed" "$work/malformed.json"
echo '{}' > "$work/no-releases-key.json"
dies_with "cannot read Proton feed" "$work/no-releases-key.json"
log "ok: dies on malformed JSON and on a feed without Releases"

proton_version_newer 1.10.0 1.9.0 || die "1.10.0 is not newer than 1.9.0"
proton_version_newer 1.0.0 - || die "nothing installed is not older than 1.0.0"
! proton_version_newer 1.9.0 1.10.0 || die "1.9.0 counted as newer than 1.10.0"
! proton_version_newer 1.9.0 1.9.0 || die "equal versions counted as newer"
log "ok: proton_version_newer orders versions numerically and treats '-' as not installed"
