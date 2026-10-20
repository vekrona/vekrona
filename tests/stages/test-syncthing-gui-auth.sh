#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export SCRATCH="$scratch" XDG_STATE_HOME="$scratch/state" HOME="$scratch/home"
mkdir -p "$scratch/stubs" "$HOME"
config="$scratch/config.xml"
calls="$scratch/calls"

# A syncthing that keeps config.xml the way the real one does: `generate` with a GUI user and a password on stdin writes
# <user> and a hash into <gui>, and the password never appears in its arguments.
write_fake "$scratch/stubs/syncthing" <<'F'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  paths) printf 'Configuration file:\n\t%s/config.xml\n\nDevice private key & certificate files:\n\t%s/key.pem\n' "$SCRATCH" "$SCRATCH" ;;
  generate)
    echo "syncthing $*" >>"$SCRATCH/calls"
    [[ "${GENERATE_FAILS:-}" != 1 ]] || exit 1
    user="${2#--gui-user=}"
    IFS= read -r password
    printf '%s' "$password" >"$SCRATCH/stdin-password"
    printf '<configuration><gui enabled="true"><address>127.0.0.1:8384</address><user>%s</user><password>$2a$10$hash</password></gui></configuration>\n' "$user" >"$SCRATCH/config.xml" ;;
  *) exit 99 ;;
esac
F
write_fake "$scratch/stubs/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$SCRATCH/calls"
F
export PATH="$scratch/stubs:$PATH"

pwfile="$XDG_STATE_HOME/vekrona/syncthing-gui-password"
run_ensure() { ensure_syncthing_gui_auth >"$scratch/out" 2>&1; }

printf '<configuration><gui enabled="true"><address>127.0.0.1:8384</address></gui></configuration>\n' >"$config"
! syncthing_gui_user_set || die "a GUI without a user is open to every local process, not set"
printf '<configuration><gui><user></user></gui></configuration>\n' >"$config"
! syncthing_gui_user_set || die "an empty user is no login"
printf '<configuration><gui><user>me</user></gui><ldap><user>x</user></ldap></configuration>\n' >"$config"
syncthing_gui_user_set || die "a GUI with a user is set"
rm -f "$config"
! syncthing_gui_user_set || die "no config at all is no login"
log "ok: syncthing_gui_user_set reads the <gui> user"

: >"$calls"
run_ensure
syncthing_gui_user_set || die "the GUI has no login after ensure_syncthing_gui_auth"
[[ "$(stat -c %a "$pwfile")" == 600 ]] || die "the password file must be 0600, got $(stat -c %a "$pwfile")"
password="$(<"$pwfile")"
((${#password} >= 24)) || die "the generated password is too short: ${#password} characters"
[[ "$(<"$scratch/stdin-password")" == "$password" ]] || die "syncthing must receive the stored password on stdin"
! grep -qF "$password" "$calls" "$scratch/out" || die "the password leaked into a command line or the log"
grep -qF "$pwfile" "$scratch/out" || die "the log must say where the password is"
mapfile -t order <"$calls"
[[ "${order[0]}" == 'systemctl --user stop syncthing.service' ]] || die "the daemon must stop before its config is edited, or it overwrites the edit: ${order[*]}"
log "ok: a fresh install gets a generated login, stored 0600 and never shown"

: >"$calls"
run_ensure
[[ ! -s "$calls" ]] || die "a second run must change nothing: $(<"$calls")"
[[ "$(<"$pwfile")" == "$password" ]] || die "a second run replaced the password"
log "ok: a second run leaves the login alone"

rm -rf "$XDG_STATE_HOME"
printf '<configuration><gui><user>me</user><password>$2a$10$mine</password></gui></configuration>\n' >"$config"
: >"$calls"
run_ensure
[[ ! -s "$calls" && ! -e "$pwfile" ]] || die "a login the user set must stay, and get no stored password: $(<"$calls")"
log "ok: a login the user set is kept"

printf '<configuration><gui></gui></configuration>\n' >"$config"
if (GENERATE_FAILS=1 ensure_syncthing_gui_auth) >/dev/null 2>&1; then die "a failed syncthing generate must fail the stage"; fi
log "ok: a failed generate fails the stage"
