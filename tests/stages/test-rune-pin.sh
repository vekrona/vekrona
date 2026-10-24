#!/usr/bin/env bash
# The rune pin helpers give stage 30 one verified download per supported architecture and die for every other machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# pin FUNCTION ARCH: runs the helper in a subshell, because a failure ends the shell; leaves its status in rc and its output in out.
pin() { rc=0; out="$("$1" "$2" 2>"$scratch/err")" || rc=$?; err="$(cat "$scratch/err")"; }

for arch in x86_64 aarch64; do
  pin rune_rpm_sha256 "$arch"
  [[ "$rc" == 0 && "$out" =~ ^[0-9a-f]{64}$ ]] || die "$arch has no 64-hex sha256: rc=$rc out=$out err=$err"
  log "ok: $arch has a pinned sha256"

  expected="https://github.com/aka-rider/rune/releases/download/v${VEKRONA_RUNE_VERSION}/rune-${VEKRONA_RUNE_VERSION}-${VEKRONA_RUNE_RELEASE}.$arch.rpm"
  pin rune_rpm_url "$arch"
  [[ "$rc" == 0 && "$out" == "$expected" ]] || die "$arch has the wrong URL: rc=$rc out=$out expected=$expected err=$err"
  log "ok: $arch downloads the pinned release's RPM"
done

pin rune_rpm_sha256 x86_64
x86_sum="$out"
pin rune_rpm_sha256 aarch64
[[ "$out" != "$x86_sum" ]] || die "x86_64 and aarch64 share one sha256, so one of them cannot match its RPM: $out"
log "ok: each architecture has its own sha256"

pin rune_pinned_nvr x
[[ "$rc" == 0 && "$out" == "${VEKRONA_RUNE_VERSION}-${VEKRONA_RUNE_RELEASE}" ]] || die "the pinned version-release is wrong: rc=$rc out=$out"
log "ok: the pinned version-release joins version and release with a dash"

for arch in riscv64 "" lizard "x86_64 "; do
  pin rune_rpm_sha256 "$arch"
  [[ "$rc" != 0 && -z "$out" && "$err" == *"rune publishes no RPM for $arch "* ]] || die "'$arch' must die with 'publishes no RPM': rc=$rc out=$out err=$err"
  log "ok: '$arch' has no RPM and dies"
done
