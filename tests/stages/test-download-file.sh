#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME" "$work/bin"
source "$REPO/lib/common.sh"

# A fake curl records its argv and writes the --output file unless FAKE_CURL_FAIL is set.
cat > "$work/bin/curl" <<'F'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_CURL_ARGV"
[[ -z "${FAKE_CURL_FAIL:-}" ]] || exit 6
while [[ $# -gt 0 ]]; do
  [[ "$1" == --output ]] && { echo payload > "$2"; break; }
  shift
done
F
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH" FAKE_CURL_ARGV="$work/argv"

download_file "https://example.invalid/a.rpm" "$work/a.rpm"
[[ "$(cat "$work/a.rpm")" == payload ]] || die "download_file did not write the destination"
log "ok: a successful download writes the file"

for flag in --fail --location --retry 5 --retry-all-errors --connect-timeout 20; do
  grep -qxe "$flag" "$FAKE_CURL_ARGV" || die "curl was not given $flag: $(tr '\n' ' ' < "$FAKE_CURL_ARGV")"
done
log "ok: transient failures are retried"

out="$(FAKE_CURL_FAIL=1 download_file "https://example.invalid/b.rpm" "$work/b.rpm" 2>&1)" && die "download_file succeeded though curl failed"
[[ "$out" == *"download failed: https://example.invalid/b.rpm"* ]] || die "failure does not name the URL: $out"
log "ok: a failed download dies naming the URL"

out="$(fetch_pinned "https://example.invalid/c" "0000" "$work/c" 2>&1)" && die "fetch_pinned accepted a wrong sha256"
[[ "$out" == *"sha256 mismatch"* ]] || die "no sha256 mismatch error: $out"
log "ok: fetch_pinned still verifies sha256"
