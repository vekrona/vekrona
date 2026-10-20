#!/usr/bin/env bash
# While a module has not answered the new query, the rows it gave for the old one are gone, and an Enter pressed meanwhile waits
# for the answer instead of activating one of them. The calculator is held back by a qalc that waits at a gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
SHIM_DIR=/tmp/vekrona-e2e-shim
GATE=/tmp/vekrona-e2e-qalc-gate
ORIGINAL_PATH_FILE=/tmp/vekrona-e2e-original-path
PANEL_HEX="$(vekrona_token_get color surface-1 dark)"
export PANEL_HEX

clipboard_is() { [[ "$(vekrona-dev sh wl-paste)" == "$1" ]]; }
export -f clipboard_is

# qalc holds an expression that ends in 13 until something is written to the gate; any other runs at once.
install_shim() {
  vekrona-dev run bash -c '
set -euo pipefail
mkdir -p "$1"
rm -f "$2"
mkfifo "$2"
cat >"$1/qalc" <<SHIM
#!/usr/bin/env bash
if [[ "\${*: -1}" == *13 ]]; then read -r <"$2"; fi
exec /usr/bin/qalc "\$@"
SHIM
chmod +x "$1/qalc"
systemctl --user show-environment | sed -n "s/^PATH=//p" >"$3"
systemctl --user set-environment "PATH=$1:$(<"$3")"
' _ "$SHIM_DIR" "$GATE" "$ORIGINAL_PATH_FILE"
  restart_shell
}
remove_shim() {
  # A held qalc would keep the gate open; releasing it first lets it end. The gate is opened for reading and writing, which
  # never waits for the other side: a write with no qalc holding on would block, and so would the ssh session around it.
  vekrona-dev run bash -c 'exec 3<>"$2"; echo >&3; systemctl --user set-environment "PATH=$(<"$3")"; rm -rf "$1" "$2" "$3"' _ "$SHIM_DIR" "$GATE" "$ORIGINAL_PATH_FILE"
  restart_shell
}
trap 'close_launcher; remove_shim' EXIT

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
install_shim

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type '/calc '
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.mode == "calc"'
vekrona-dev type '1+1'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.selectedId == "calc:result"' || { launcher_state; die "the calculator must answer 1+1"; }

vekrona-dev type '3'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.query == "1+13" and .rows == 0' || { launcher_state; die "the answer to 1+1 must not stay listed for the query 1+13 while qalc has not answered"; }
log "ok: the rows of the old query are gone while the calculator has not answered the new one"

vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.open and .rows == 0' || die "an Enter with nothing to activate must keep the launcher open and wait"
vekrona-dev run bash -c 'echo >"$1"' _ "$GATE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || { launcher_state; die "the Enter that waited must activate the answer once it arrives"; }
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- clipboard_is 14 || die "the waiting Enter must copy the answer to 1+13, 14, but the clipboard holds: $(vekrona-dev sh wl-paste)"
log "ok: an Enter pressed while the calculator was answering activates the new answer, not the old one"
