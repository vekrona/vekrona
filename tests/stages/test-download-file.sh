#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME" "$work/bin"
source "$REPO/tests/lib.sh"

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

# A redirector may send curl to plain http, where whoever sits on the path rewrites the file, and a URL with [ ] or { } would be
# expanded into several downloads.
argv="$(tr '\n' ' ' < "$FAKE_CURL_ARGV")"
for option in '--proto =https ' '--proto-redir =https ' '--globoff '; do
  [[ "$argv" == *"$option"* ]] || die "curl was not given ${option% }: $argv"
done
log "ok: a download is https only, also after a redirect, and takes the URL literally"

out="$(FAKE_CURL_FAIL=1 download_file "https://example.invalid/b.rpm" "$work/b.rpm" 2>&1)" && die "download_file succeeded though curl failed"
[[ "$out" == *"download failed: https://example.invalid/b.rpm"* ]] || die "failure does not name the URL: $out"
log "ok: a failed download dies naming the URL"

# The fake curl writes "payload\n" to every destination.
for algorithm in sha256 sha512; do
  sum="$(echo payload | "${algorithm}sum" | awk '{print $1}')"
  fetch_verified "https://example.invalid/c" "$algorithm" "$sum" "$work/c-$algorithm"
  [[ -f "$work/c-$algorithm" ]] || die "fetch_verified did not keep a file whose $algorithm matches"
done
log "ok: fetch_verified keeps a download whose checksum matches (sha256, sha512)"

for algorithm in sha256 sha512; do
  rm -f "$work/d"
  out="$(fetch_verified "https://example.invalid/d" "$algorithm" "0000" "$work/d" 2>&1)" && die "fetch_verified accepted a wrong $algorithm"
  [[ "$out" == *"$algorithm mismatch for https://example.invalid/d"* ]] || die "no $algorithm mismatch error: $out"
  [[ ! -e "$work/d" ]] || die "fetch_verified left the unverified $algorithm download behind"
done
log "ok: fetch_verified dies on a checksum mismatch and removes the download"

out="$(fetch_verified "https://example.invalid/f" md5 "0000" "$work/f" 2>&1)" && die "fetch_verified accepted md5"
[[ "$out" == *"unsupported checksum algorithm"* ]] || die "no unsupported-algorithm error: $out"
[[ ! -e "$work/f" ]] || die "fetch_verified downloaded before rejecting the algorithm"
log "ok: an unknown algorithm dies before downloading"
