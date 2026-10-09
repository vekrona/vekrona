#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/rpmdb"

# Fake rpm database (one file per installed package) and a systemctl that logs every call: gdm is enabled, enabling
# greetd fails, so a run that gets past the package checks stops right after it has disabled gdm.
cat > "$work/bin/rpm" <<'F'
#!/usr/bin/env bash
case "$*" in
  "-q --requires sway")   echo "libwlroots-0.19.so()(64bit)" ;;
  "-q --whatprovides "*)  echo wlroots0.19 ;;
  *)                      [[ "$1" == -q && -e "$FAKE_RPMDB/$2" ]] ;;
esac
F
cat > "$work/bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_LOG"
case "$1 ${2-}" in
  "is-enabled gdm") echo enabled ;;
  "is-enabled "*)   echo disabled; exit 1 ;;
  disable*)         ;;
  *)                exit 1 ;;
esac
F
printf '#!/usr/bin/env bash\necho "dnf $*" >> "$FAKE_LOG"\n' > "$work/bin/dnf"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$work/bin/sudo"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" FAKE_RPMDB="$work/rpmdb" FAKE_LOG="$work/calls.log" XDG_CURRENT_DESKTOP=sway

switch_dm() { # switch_dm <installed package>...: runs 90a; its exit status is the stage's
  rm -f "$work/rpmdb"/* "$FAKE_LOG"; touch "$FAKE_LOG"
  local p; for p in "$@"; do touch "$work/rpmdb/$p"; done
  bash "$ROOT/stages/90a-switch-dm.sh" >"$work/out" 2>&1
}
gdm_disabled() { grep -qx 'systemctl disable gdm' "$FAKE_LOG"; }

for missing in greetd tuigreet; do
  other=greetd; [[ "$missing" == greetd ]] && other=tuigreet
  if switch_dm sway "$other"; then die "90a must fail without $missing"; fi
  grep -qF "$missing is not installed" "$work/out" || die "90a without $missing does not name it: $(cat "$work/out")"
  ! gdm_disabled || die "gdm was disabled although $missing is not installed"
  log "ok: without $missing the stage dies before gdm is disabled"
done

switch_dm sway greetd tuigreet && die "the fake systemctl fails enabling greetd" || true
gdm_disabled || die "with greetd and tuigreet installed the stage must reach disabling gdm: $(cat "$work/out")"
log "ok: with greetd and tuigreet installed the stage proceeds to switch the login manager"
