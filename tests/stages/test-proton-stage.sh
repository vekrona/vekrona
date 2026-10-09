#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
source "$REPO/tests/lib.sh"

# `vekrona-proton stage` insists on root. A user namespace that maps the caller to uid 0 gives it that, with no
# privileges on the host.
unshare -r true || die "cannot create a user namespace to stand in for root"

mkdir -p "$work/bin" "$work/feeds" "$work/rpmdb" "$work/repo"
export PATH="$work/bin:$PATH" VEKRONA_PROTON_REPO_DIR="$work/repo" \
  FAKE_FEEDS="$work/feeds" FAKE_RPMDB="$work/rpmdb" FAKE_CURL_LOG="$work/curl.log" FAKE_CREATEREPO_LOG="$work/createrepo.log"

# The fake curl serves a feed per URL and, for any other URL, an "rpm" whose content names its package and version
# (<name>-<version>.rpm). The fake rpm reads that content back.
cat > "$work/bin/curl" <<'F'
#!/usr/bin/env bash
url="${*: -1}"
dest=""
while [[ $# -gt 0 ]]; do [[ "$1" == --output ]] && dest="$2"; shift; done
echo "$url" >> "$FAKE_CURL_LOG"
case "$url" in
  */mail/linux/version.json) cp "$FAKE_FEEDS/proton-mail.json" "$dest" ;;
  */PassDesktop/linux/x64/version.json) cp "$FAKE_FEEDS/proton-pass.json" "$dest" ;;
  */authenticator/linux/version.json) cp "$FAKE_FEEDS/proton-authenticator.json" "$dest" ;;
  *) base="${url##*/}"; base="${base%.rpm}"; printf '%s %s' "${base%-*}" "${base##*-}" > "$dest" ;;
esac
F
cat > "$work/bin/rpm" <<'F'
#!/usr/bin/env bash
if [[ "$1" == -qp ]]; then cat "${*: -1}"; exit 0; fi
name="${*: -1}"
[[ -f "$FAKE_RPMDB/$name" ]] || { echo "package $name is not installed"; exit 1; }
if [[ " $* " == *" --qf "* ]]; then cat "$FAKE_RPMDB/$name"; else echo "$name"; fi
F
cat > "$work/bin/createrepo_c" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CREATEREPO_LOG"
mkdir -p "${*: -1}/repodata"
touch "${*: -1}/repodata/repomd.xml"
F
chmod +x "$work/bin/"*

# publish NAME VERSION [PAYLOAD_VERSION]: the feed of NAME offers one Stable release; its rpm holds PAYLOAD_VERSION.
publish() {
  local name="$1" version="$2" content="$1 ${3:-$2}"
  jq -n --arg version "$version" --arg url "https://proton.me/download/app/$name-${3:-$2}.rpm" \
    --arg sum "$(printf '%s' "$content" | sha512sum | awk '{print $1}')" \
    '{Releases: [{CategoryName: "Stable", Version: $version, RolloutProportion: 1,
       File: [{Identifier: ".rpm (Fedora/RHEL)", Url: $url, Sha512CheckSum: $sum}]}]}' > "$FAKE_FEEDS/$name.json"
}
install_fake() { echo "$2" > "$FAKE_RPMDB/$1"; }

stage() { unshare -r "$REPO/bin/vekrona-proton" stage 2>&1; }
rpm_downloads() { { grep -c '\.rpm$' "$FAKE_CURL_LOG" || true; } }
repo_rpms() { (cd "$work/repo" && ls | grep -v '^repodata$' | paste -sd' '); }
reset_logs() { : > "$FAKE_CURL_LOG"; : > "$FAKE_CREATEREPO_LOG"; }

publish proton-mail 1.10.0
publish proton-pass 1.0.0
publish proton-authenticator 2.0.0
reset_logs

out="$("$REPO/bin/vekrona-proton" stage 2>&1)" && die "stage ran as a regular user"
[[ "$out" == *"must run as root"* ]] || die "no root requirement error: $out"
[[ -z "$(ls -A "$work/repo")" ]] || die "stage touched the repo before checking for root"
log "ok: stage refuses to run as a regular user"

stage >/dev/null
[[ "$(repo_rpms)" == "proton-authenticator-2.0.0.rpm proton-mail-1.10.0.rpm proton-pass-1.0.0.rpm" ]] || die "first stage left: $(repo_rpms)"
[[ -f "$work/repo/repodata/repomd.xml" ]] || die "first stage built no repo metadata"
log "ok: a first stage downloads the three latest rpms and builds the repo"

reset_logs
stage >/dev/null
[[ "$(rpm_downloads)" -eq 0 ]] || die "second stage downloaded again"
log "ok: staging again with nothing new downloads nothing"

publish proton-mail 1.11.0
install_fake proton-mail 1.10.0
reset_logs
stage >/dev/null
[[ "$(repo_rpms)" == "proton-authenticator-2.0.0.rpm proton-mail-1.11.0.rpm proton-pass-1.0.0.rpm" ]] || die "after a Mail release the repo holds: $(repo_rpms)"
[[ "$(rpm_downloads)" -eq 1 ]] || die "expected one rpm download, got $(rpm_downloads)"
[[ -s "$FAKE_CREATEREPO_LOG" ]] || die "metadata not refreshed after a new rpm"
log "ok: a new release replaces the older rpm of that package only"

rm "$work/repo/proton-pass-1.0.0.rpm"
install_fake proton-pass 1.0.0
reset_logs
stage >/dev/null
[[ "$(rpm_downloads)" -eq 0 ]] || die "downloaded a release that is already installed"
log "ok: an rpm whose version is already installed is not downloaded"

echo '{"Releases": []}' > "$FAKE_FEEDS/proton-pass.json"
out="$(stage)" && die "stage survived a feed with no usable release"
[[ "$out" == *"no Stable release"* ]] || die "no feed error: $out"
log "ok: a feed without a usable release fails the stage"

publish proton-pass 1.1.0
publish proton-mail 1.12.0 9.9.9
out="$(stage)" && die "stage accepted an rpm whose content differs from the feed"
[[ "$out" == *"expected 'proton-mail 1.12.0'"* ]] || die "no content error: $out"
[[ "$(repo_rpms)" == *proton-mail-1.11.0.rpm* && "$(repo_rpms)" != *1.12.0* ]] || die "bad rpm landed in the repo: $(repo_rpms)"
log "ok: an rpm that is not the feed's package and version never reaches the repo"

publish proton-mail 1.12.0
jq '.Releases[0].File[0].Sha512CheckSum = ("b" * 128)' "$FAKE_FEEDS/proton-mail.json" > "$work/tampered.json"
mv "$work/tampered.json" "$FAKE_FEEDS/proton-mail.json"
out="$(stage)" && die "stage accepted an rpm with the wrong sha512"
[[ "$out" == *"sha512 mismatch"* ]] || die "no sha512 error: $out"
[[ "$(repo_rpms)" != *1.12.0* ]] || die "unverified rpm landed in the repo: $(repo_rpms)"
log "ok: an rpm failing its sha512 never reaches the repo"
