#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# A throwaway HOME, set before lib/common.sh derives the Firefox profile root from it.
export HOME="$scratch/home"
mkdir -p "$HOME/.mozilla/firefox" "$scratch/stubs"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

# pgrep answers with the status PGREP_STATUS names: 0 a Firefox runs the profile, 1 none does, anything else is its own failure.
write_fake "$scratch/stubs/pgrep" <<'F'
#!/usr/bin/env bash
echo "pgrep $*" >>"$SCRATCH/pgrep-calls"
exit "${PGREP_STATUS:-1}"
F
export SCRATCH="$scratch" PATH="$scratch/stubs:$PATH"

root="$HOME/.mozilla/firefox"
ini="$root/profiles.ini"
write_profiles() {
  printf '[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=default\nIsRelative=1\nPath=a.default\nDefault=1\n\n[Profile1]\nName=vekrona-syncthing\nIsRelative=0\nPath=%s/vekrona-syncthing\n\n[Profile2]\nName=vekrona-youtube\nIsRelative=0\nPath=%s/vekrona-youtube\n' "$root" "$root" >"$ini"
  mkdir -p "$root/a.default" "$root/vekrona-syncthing/chrome" "$root/vekrona-youtube"
  touch "$root/vekrona-syncthing/prefs.js"
}

write_profiles
retire_webapp_profile syncthing >/dev/null 2>&1
! grep -q 'vekrona-syncthing' "$ini" || die "the retired profile is still in profiles.ini: $(<"$ini")"
[[ ! -e "$root/vekrona-syncthing" ]] || die "the retired profile directory is still there"
log "ok: the profile's entry and directory go"

grep -qx 'Name=default' "$ini" && grep -qx 'Name=vekrona-youtube' "$ini" && grep -qx 'StartWithLastProfile=1' "$ini" \
  || die "the other profiles and the general section must stay: $(<"$ini")"
[[ -d "$root/vekrona-youtube" && -d "$root/a.default" ]] || die "another profile's directory was removed"
log "ok: no other profile or setting is touched"

before="$(<"$ini")"
retire_webapp_profile syncthing >/dev/null 2>&1
[[ "$(<"$ini")" == "$before" ]] || die "a second run changed profiles.ini"
log "ok: a second run changes nothing"

rm -f "$ini"
retire_webapp_profile syncthing >/dev/null 2>&1
[[ ! -e "$ini" ]] || die "no profiles.ini is no reason to create one"
log "ok: a Firefox with no profiles.ini is left alone"

write_profiles
if (PGREP_STATUS=0 retire_webapp_profile syncthing) >/dev/null 2>&1; then die "a profile a running Firefox holds must not be removed"; fi
[[ -d "$root/vekrona-syncthing" ]] && grep -q 'vekrona-syncthing' "$ini" || die "the profile was touched although a Firefox runs it"
grep -qF -- '-P vekrona-syncthing ' "$scratch/pgrep-calls" || die "pgrep must look for the profile by its name: $(<"$scratch/pgrep-calls")"
log "ok: a running Firefox on the profile stops the retirement"

if (PGREP_STATUS=2 retire_webapp_profile syncthing) >/dev/null 2>&1; then die "a failing pgrep cannot tell that no Firefox runs the profile, and must fail the stage"; fi
log "ok: a pgrep that fails fails the stage"
