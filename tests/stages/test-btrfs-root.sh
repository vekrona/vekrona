#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

repo="$scratch/repo"
mkdir -p "$repo/lib" "$repo/stages" "$scratch/stubs" "$scratch/runtime" "$scratch/home"
cp "$ROOT/install.sh" "$repo/"
cp "$ROOT/lib/common.sh" "$repo/lib/"
for stage in 20-snapper 50-user 70-verify; do
  printf '#!/bin/sh\necho %s >> "%s/ran"\n' "$stage" "$scratch" > "$repo/stages/$stage.sh"
done

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$scratch/stubs/$1"; chmod +x "$scratch/stubs/$1"; }
stub sudo 'exit 0'
stub swaymsg 'exit 0'
set_root_fs() { stub findmnt "echo $1"; }
export PATH="$scratch/stubs:$PATH"
export HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/runtime"
unset SWAYSOCK

run_install() { rm -f "$scratch/ran"; "$repo/install.sh" "$@" >"$scratch/stdout" 2>"$scratch/stderr"; }
stages_ran() { [[ -f "$scratch/ran" ]] && tr '\n' ' ' < "$scratch/ran" || true; }

set_root_fs ext4
if run_install 20-snapper; then die "install on an ext4 root must fail"; fi
grep -qF 'root filesystem is ext4' "$scratch/stderr" && grep -qF 'needs btrfs' "$scratch/stderr" \
  || die "error does not name the found filesystem and btrfs: $(cat "$scratch/stderr")"
[[ -z "$(stages_ran)" ]] || die "a stage ran before the btrfs check failed: $(stages_ran)"
log "ok: an ext4 root fails before any stage runs, naming ext4 and btrfs"

if run_install 50-user 20-snapper; then die "install with 20-snapper among the stages must fail on an ext4 root"; fi
[[ -z "$(stages_ran)" ]] || die "50-user ran before the btrfs check failed: $(stages_ran)"
log "ok: the check precedes every stage, not just 20-snapper"

if run_install 70-verify; then die "70-verify alone must fail on an ext4 root, it checks the snapper stage by default"; fi
grep -qF 'needs btrfs' "$scratch/stderr" || die "70-verify alone did not report the btrfs requirement: $(cat "$scratch/stderr")"
log "ok: 70-verify alone requires btrfs because it verifies snapper"

run_install 50-user || die "a run without the snapper stage needs no btrfs root: $(cat "$scratch/stderr")"
run_install --skip 20-snapper 70-verify || die "70-verify with snapper skipped needs no btrfs root: $(cat "$scratch/stderr")"
run_install --list || die "--list must not check the root filesystem: $(cat "$scratch/stderr")"
log "ok: runs that do not involve snapper, and --list, work on any root"

set_root_fs btrfs
run_install 50-user 20-snapper || die "install on a btrfs root failed: $(cat "$scratch/stderr")"
[[ "$(stages_ran)" == "50-user 20-snapper " ]] || die "stages did not run on a btrfs root: $(stages_ran)"
log "ok: a btrfs root proceeds"

stub findmnt 'exit 1'
if run_install 20-snapper; then die "install must fail when the root filesystem cannot be determined"; fi
grep -qF 'findmnt failed' "$scratch/stderr" || die "error does not say findmnt failed: $(cat "$scratch/stderr")"
[[ -z "$(stages_ran)" ]] || die "a stage ran after findmnt failed: $(stages_ran)"
log "ok: an undeterminable root filesystem fails"
