#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
# xremap runs as a system service under its own user, which alone may read the keyboards; the session user is not in the input group.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/stages/update-fakes.sh" # run_as_root

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/state"

UNIT="$ROOT/etc/systemd/system/xremap.service"
unit_has() { grep -qxF -- "$1" "$UNIT" || die "xremap.service lacks: $1"; }
unit_has "User=xremap"
unit_has "DevicePolicy=closed"
unit_has "DeviceAllow=char-input rw"
unit_has "DeviceAllow=/dev/uinput rw"
unit_has "NoNewPrivileges=yes"
unit_has "ExecStartPre=+/usr/local/lib/vekrona/libexec/vekrona-xremap-access"
unit_has "ExecStart=/usr/bin/xremap-wlroots --watch=config,device /etc/xremap/config.yml"
! grep -qE '^(SupplementaryGroups|ProtectHome)=' "$UNIT" || die "the unit sets what the user's runtime directory and the input group (sysusers.d) need unset"
[[ -x "$ROOT/libexec/vekrona-xremap-access" ]] || die "the +-step of the unit is not executable in libexec/"
[[ -x "$ROOT/libexec/vekrona-super-state" ]] || die "vekrona-super-state is not executable in libexec/"
grep -qx "PathExistsGlob=/run/user/@UID@/wayland-\[0-9\]" "$ROOT/etc/systemd/system/xremap.path" || die "xremap.path does not wait for a Wayland socket"
grep -qx 'u xremap - "xremap key remapper" /var/empty /usr/sbin/nologin' "$ROOT/etc/sysusers.d/vekrona-xremap.conf" || die "no xremap user in sysusers.d"
grep -qx 'm xremap input' "$ROOT/etc/sysusers.d/vekrona-xremap.conf" || die "the xremap user is not put in the input group"
grep -q 'TAG-="uaccess"' "$ROOT/etc/udev/rules.d/70-vekrona-uinput.rules" || die "the seat user still gets an ACL on /dev/uinput"
[[ ! -e "$ROOT/config/systemd-user/xremap.service" ]] || die "the user unit is back: two xremaps would grab the keyboards"
log "ok: xremap is a system service of its own user with the input and uinput devices only, started by a Wayland socket"

xremap-wlroots --validate-config "$ROOT/config/xremap/config.yml" >/dev/null || die "the xremap config does not validate"
for terminal in com.mitchellh.ghostty vekrona.agent vekrona.perf; do
  grep -q "not: &terminals \[.*$terminal" "$ROOT/config/xremap/config.yml" || die "$terminal is not one of the terminals the cmd layer leaves alone"
done
log "ok: the config validates and treats the btop window (vekrona.perf) as a terminal"

# --- vekrona-super-state ---
export VEKRONA_SUPER_STATE_DIR="$work/state"
"$ROOT/libexec/vekrona-super-state" L down
[[ "$(<"$work/state/super-L")" == 1 ]] || die "Super_L down is not 1"
"$ROOT/libexec/vekrona-super-state" L up
[[ "$(<"$work/state/super-L")" == 0 ]] || die "Super_L up is not 0"
for args in "X down" "L sideways" "L" ""; do
  # shellcheck disable=SC2086
  if "$ROOT/libexec/vekrona-super-state" $args 2>/dev/null; then die "accepted the arguments '$args'"; fi
done
[[ -z "$(find "$work/state" -type f ! -name super-L)" ]] || die "an unknown key wrote a file: $(ls "$work/state")"
log "ok: vekrona-super-state records Super down and up and refuses anything else"

# --- wait-super-release.py: exits when no Super key is down, and only then ---
printf 1 >"$work/state/super-R"; printf 0 >"$work/state/super-L"
python3 "$ROOT/config/vekrona-app-switch/wait-super-release.py" &
waiter=$!
until pgrep -P "$waiter" -x inotifywait >/dev/null || ! kill -0 "$waiter" 2>/dev/null; do :; done
kill -0 "$waiter" 2>/dev/null || die "the waiter ended while Super_R was down"
printf 0 >"$work/state/super-R"
wait "$waiter" || die "the waiter did not end cleanly after Super_R went up"
printf 0 >"$work/state/super-R"
python3 "$ROOT/config/vekrona-app-switch/wait-super-release.py" || die "the waiter did not return at once with no Super key down"
log "ok: the app switcher's waiter returns when the last Super key is up"
unset VEKRONA_SUPER_STATE_DIR

# --- vekrona-xremap-access: the ACLs, and the one compositor it may serve ---
write_fake "$work/bin/setfacl" <<'F'
#!/usr/bin/env bash
echo "setfacl $*" >>"$WORK/acl.log"
F
write_fake "$work/bin/ss" <<'F'
#!/usr/bin/env bash
cat "$WORK/ss.out"
F
export WORK="$work" PATH="$work/bin:$PATH" VEKRONA_XREMAP_ENV_FILE="$work/wayland.env"
access() { : >"$work/acl.log"; rm -f "$work/wayland.env"; run_as_root "$ROOT/libexec/vekrona-xremap-access" 2>"$work/err"; }

SWAY='u_str LISTEN 0 128 /run/user/1000/wayland-1 7788 * 0 users:(("sway",pid=2284,fd=12))'
OTHER='u_str LISTEN 0 128 /run/user/1000/wayland-2 7790 * 0 users:(("quickshell",pid=2301,fd=9))'
OTHER_SWAY='u_str LISTEN 0 128 /run/user/1001/wayland-1 8800 * 0 users:(("sway",pid=3300,fd=12))'

printf '%s\n%s\n' "$SWAY" "$OTHER" >"$work/ss.out"
access || die "the one sway socket was refused: $(cat "$work/err")"
grep -qx 'setfacl -m u:xremap:x /run/user/1000' "$work/acl.log" || die "the runtime directory is not made traversable: $(cat "$work/acl.log")"
grep -qx 'setfacl -m u:xremap:rw /run/user/1000/wayland-1' "$work/acl.log" || die "the socket is not opened to xremap: $(cat "$work/acl.log")"
[[ "$(wc -l <"$work/acl.log")" -eq 2 ]] || die "access went beyond the socket and its directory: $(cat "$work/acl.log")"
[[ "$(<"$work/wayland.env")" == $'XDG_RUNTIME_DIR=/run/user/1000\nWAYLAND_DISPLAY=wayland-1' ]] || die "wrong environment: $(cat "$work/wayland.env")"
log "ok: xremap gets the sway socket and its directory, not other clients' sockets"

printf '%s\n%s\n' "$SWAY" "$OTHER_SWAY" >"$work/ss.out"
if access; then die "two sway sessions were not refused"; fi
grep -q 'more than one Sway' "$work/err" || die "two sessions: no reason: $(cat "$work/err")"
printf '%s\n' "$OTHER" >"$work/ss.out"
if access; then die "a machine without sway was not refused"; fi
grep -q 'no Sway Wayland socket' "$work/err" || die "no sway: no reason: $(cat "$work/err")"
[[ ! -s "$work/acl.log" ]] || die "access was granted without a sway socket"
log "ok: no or ambiguous compositor grants nothing"

# --- xremap.path is rendered for one user's runtime directory ---
source "$ROOT/lib/xremap.sh"
rendered="$(render_xremap_path_unit 1234 <"$ROOT/etc/systemd/system/xremap.path")"
grep -qx 'PathExistsGlob=/run/user/1234/wayland-\[0-9\]' <<<"$rendered" || die "the path unit does not watch the user's runtime directory: $rendered"
! grep -q '@UID@' <<<"$rendered" || die "a placeholder is left in the path unit"
for uid in "" "root" "1 2"; do
  if (render_xremap_path_unit "$uid" <"$ROOT/etc/systemd/system/xremap.path") >/dev/null 2>&1; then die "accepted the uid '$uid'"; fi
done
log "ok: xremap.path watches the runtime directory of the installing user, because systemd cannot watch a glob in the directory part"
