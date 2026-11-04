#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export SCRATCH="$scratch" XDG_STATE_HOME="$scratch/state" HOME="$scratch/home"
mkdir -p "$scratch/stubs" "$HOME"
config="$scratch/config.xml"
calls="$scratch/calls"
socket="/run/user/$(id -u)/syncthing/gui.sock"

# A syncthing that knows only what the stage uses: `paths`, and `generate`, which writes the default config (a TCP GUI, as the
# real one does) when there is none.
write_fake "$scratch/stubs/syncthing" <<'F'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  paths) printf 'Configuration file:\n\t%s/config.xml\n\nDevice private key & certificate files:\n\t%s/key.pem\n' "$SCRATCH" "$SCRATCH" ;;
  generate)
    echo "syncthing $*" >>"$SCRATCH/calls"
    [[ "${GENERATE_FAILS:-}" != 1 ]] || exit 1
    printf '<configuration>\n    <gui enabled="true">\n        <address>127.0.0.1:8384</address>\n        <apikey>GENERATED</apikey>\n    </gui>\n</configuration>\n' >"$SCRATCH/config.xml" ;;
  *) exit 99 ;;
esac
F
# `stop` keeps the config as it was at that moment, to tell whether the edit came after it.
write_fake "$scratch/stubs/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$SCRATCH/calls"
if [[ "$*" == '--user stop syncthing.service' ]]; then
  if [[ -f "$SCRATCH/config.xml" ]]; then cp "$SCRATCH/config.xml" "$SCRATCH/config-at-stop.xml"; else rm -f "$SCRATCH/config-at-stop.xml"; fi
fi
F
# python3 reads and edits the XML. BAD_EDIT=1 makes its `edit` print the config unchanged, as an edit that did not work would.
real_python="$(command -v python3)"
write_fake "$scratch/stubs/python3" <<F
#!/usr/bin/env bash
if [[ "\${BAD_EDIT:-}" == 1 && "\$3" == edit ]]; then cat "\$SCRATCH/config.xml"; else exec "$real_python" "\$@"; fi
F
export PATH="$scratch/stubs:$PATH"

pwfile="$XDG_STATE_HOME/vekrona/syncthing-gui-password"
run_ensure() { ensure_syncthing_gui_socket >"$scratch/out" 2>&1; }
# The config of a daemon with a login on the old TCP address, laid out the way Syncthing writes it. The <address> of the device is
# not the GUI's and must survive.
write_login_config() {
  cat >"$config" <<XML
<configuration version="51">
    <device id="AAAAAAA-BBBBBBB"><address>dynamic</address></device>
    <gui enabled="true" tls="false">
        <address>${1:-127.0.0.1:8384}</address>
        <user>vekrona</user>
        <password>\$2a\$10\$hash</password>
        <apikey>KEY</apikey>
    </gui>
    <options><listenAddress>default</listenAddress></options>
</configuration>
XML
}

[[ "$(syncthing_gui_socket)" == "$socket" ]] || die "the socket must be in the runtime directory of this uid, $socket, but it is $(syncthing_gui_socket)"
log "ok: the socket is in /run/user/<uid>/syncthing"

write_login_config
[[ "$(syncthing_gui_address "$config")" == 127.0.0.1:8384 ]] || die "syncthing_gui_address read '$(syncthing_gui_address "$config")', not the <gui> address"
syncthing_gui_login_set "$config" || die "a GUI with a user and a password has a login"
rm -f "$config"
[[ -z "$(syncthing_gui_address "$config")" ]] || die "no config at all has no address"
! syncthing_gui_login_set "$config" || die "no config at all has no login"
printf '<configuration><gui><address>a</address><user></user><password></password></gui></configuration>\n' >"$config"
! syncthing_gui_login_set "$config" || die "an empty user and password are no login"
printf '<configuration><gui><user>me</user></gui></configuration>\n' >"$config"
syncthing_gui_login_set "$config" || die "a user alone is a login to remove"
printf '<configuration><gui><password>$2a$10$h</password></gui></configuration>\n' >"$config"
syncthing_gui_login_set "$config" || die "a password alone is a login to remove"
printf '<configuration><gui><address>a</address></gui><ldap><user>x</user></ldap></configuration>\n' >"$config"
! syncthing_gui_login_set "$config" || die "a user outside <gui> is not a GUI login"
printf '<configuration>\n    <gui enabled="true">\n        <address>a</address>\n    </gui>\n    <ldap>\n        <user>x</user>\n        <address>other</address>\n    </ldap>\n</configuration>\n' >"$config"
! syncthing_gui_login_set "$config" || die "a user outside <gui> is not a GUI login, in a config laid out over many lines"
[[ "$(syncthing_gui_address "$config")" == a ]] || die "the address of another element leaked into the GUI's: '$(syncthing_gui_address "$config")'"
printf '<configuration>\n    <gui enabled="true" tls="true">\n        <address>a</address>\n    </gui>\n    <options tls="true">\n        <user>x</user>\n    </options>\n</configuration>\n' >"$config"
syncthing_gui_tls_set "$config" || die "tls=\"true\" on <gui> is a TLS GUI in a config laid out over many lines"
printf '<configuration><gui><address>a</address>\n' >"$config"
if (syncthing_gui_login_set "$config") >/dev/null 2>&1; then die "a config that is not XML cannot be read, and must be an error rather than no login"; fi
printf '<configuration><gui enabled="true" tls="true"><address>a</address></gui></configuration>\n' >"$config"
syncthing_gui_tls_set "$config" || die "tls=\"true\" is a TLS GUI"
printf '<configuration><gui enabled="true" tls="false"><address>a</address></gui></configuration>\n' >"$config"
! syncthing_gui_tls_set "$config" || die "tls=\"false\" is no TLS GUI"
log "ok: syncthing_gui_address, syncthing_gui_login_set and syncthing_gui_tls_set read the <gui> element"

write_login_config
mkdir -p "$(dirname "$pwfile")"
echo old-password >"$pwfile"
: >"$calls"
run_ensure
[[ "$(syncthing_gui_address "$config")" == "$socket" ]] || die "the GUI address is '$(syncthing_gui_address "$config")', not $socket"
log "ok: the GUI address is rewritten to the socket"
! syncthing_gui_login_set "$config" || die "the login is still in the config"
! grep -q '<user>\|<password>' "$config" || die "<user> or <password> is still in the config: $(<"$config")"
log "ok: the user and the password are removed"
grep -q '<apikey>KEY</apikey>' "$config" || die "the API key must stay, the REST client needs it: $(<"$config")"
grep -q '<address>dynamic</address>' "$config" || die "the address of a device is not the GUI's and must stay: $(<"$config")"
[[ ! -e "$pwfile" ]] || die "the password file of the retired login must be deleted"
log "ok: the password file is deleted and nothing else in the config changed"
mapfile -t order <"$calls"
[[ "${order[0]}" == 'systemctl --user stop syncthing.service' ]] || die "the daemon must stop first: ${order[*]}"
grep -q '<user>vekrona</user>' "$scratch/config-at-stop.xml" || die "the config was edited before the daemon stopped, so the daemon would overwrite the edit"
log "ok: the daemon stops before the config is edited"

: >"$calls"
echo old-password >"$pwfile"
run_ensure
[[ ! -s "$calls" ]] || die "a config that is right must not stop the daemon: $(<"$calls")"
[[ ! -e "$pwfile" ]] || die "a password file left over must go even when the config is right"
log "ok: a second run changes nothing, and still removes a left-over password file"

write_login_config "$socket"
: >"$calls"
run_ensure
! syncthing_gui_login_set "$config" || die "a login the user set on the socket address must go too"
[[ "$(syncthing_gui_address "$config")" == "$socket" ]] || die "the socket address was lost"
[[ "$(head -n1 "$calls")" == 'systemctl --user stop syncthing.service' ]] || die "removing a login needs the daemon stopped first"
log "ok: a login on the socket address is removed"

rm -f "$config" "$scratch/config-at-stop.xml"
: >"$calls"
run_ensure
[[ "$(syncthing_gui_address "$config")" == "$socket" ]] || die "a fresh install must get the socket: '$(syncthing_gui_address "$config")'"
grep -q '<apikey>GENERATED</apikey>' "$config" || die "the generated config's API key was lost"
mapfile -t order <"$calls"
[[ "${order[0]}" == 'systemctl --user stop syncthing.service' && "${order[1]}" == 'syncthing generate' ]] || die "a fresh install stops the daemon, then generates its config: ${order[*]}"
log "ok: a fresh install generates the config and moves its GUI to the socket"

rm -f "$config"
if (GENERATE_FAILS=1 ensure_syncthing_gui_socket) >/dev/null 2>&1; then die "a failed syncthing generate must fail the stage"; fi
log "ok: a failed generate fails the stage"

printf '<configuration><options/></configuration>\n' >"$config"
if (ensure_syncthing_gui_socket) >/dev/null 2>&1; then die "a config without a <gui> element cannot be moved to the socket and must fail the stage"; fi
log "ok: a config with no <gui> fails the stage instead of leaving it on TCP"

# A GUI with a login and no <address>: the sed edit of an earlier version removed the login and set no address, which left a
# GUI on Syncthing's default TCP address without any login.
printf '<configuration>\n    <gui enabled="true" tls="false">\n        <user>vekrona</user>\n        <password>x</password>\n        <apikey>KEY</apikey>\n    </gui>\n</configuration>\n' >"$config"
run_ensure
syncthing_gui_on_socket "$config" "$socket" || die "a GUI without an <address> must get the socket: $(<"$config")"
grep -q '<apikey>KEY</apikey>' "$config" || die "the API key was lost: $(<"$config")"
log "ok: a GUI without an <address> gets the socket"

printf '<configuration>\n    <gui enabled="true" tls="true">\n        <address>%s</address>\n        <apikey>KEY</apikey>\n    </gui>\n</configuration>\n' "$socket" >"$config"
run_ensure
! syncthing_gui_tls_set "$config" || die "a TLS GUI cannot be served to vekrona-sync: $(<"$config")"
syncthing_gui_on_socket "$config" "$socket" || die "the socket address was lost: $(<"$config")"
log "ok: a TLS GUI on the socket is switched to plain HTTP"

write_login_config
before="$(<"$config")"
if (BAD_EDIT=1 ensure_syncthing_gui_socket) >"$scratch/out" 2>&1; then die "an edit that leaves the login in must fail the stage"; fi
[[ "$(<"$config")" == "$before" ]] || die "a failed edit must leave config.xml as it was: $(<"$config")"
[[ "$(find "$scratch" -maxdepth 1 -name 'config.xml.*')" == "" ]] || die "a failed edit left its temp copy behind"
grep -q 'stays as it was' "$scratch/out" || die "the failure must say that the config is untouched: $(<"$scratch/out")"
log "ok: an edit that does not verify leaves config.xml untouched and fails the stage"
