# shellcheck shell=bash
# Shell side of vekrona-vpn: what the stages do about earlier installs of it.

VEKRONA_RETIRED_KILLSWITCH_UNIT=vekrona-vpn-killswitch.service

# Retires vekrona-vpn-killswitch.service, which earlier checkouts shipped: it loaded the table `inet vekrona-vpn` and its ExecStop
# deleted it. ensure_system_unit_file_absent stops a unit only after its file is gone, so no ExecStop runs and the table would stay
# loaded, rejecting everything, while the state file (which the new tmpfiles entry creates as disarmed) says nothing is armed and the
# bar offers no Off. So when the unit file is there, the table goes first (the same declare-then-delete as render_disarm() in
# lib/vekrona_vpn.py, which succeeds when the table is not loaded), and the unit file after it: a run that stops in between finds
# the unit file again and deletes the table again. Without the unit file the table, if any, was armed by the current design and
# stays: only "vekrona-vpn off" removes that.
retire_vpn_killswitch_unit() {
  local unit_file="${VEKRONA_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$VEKRONA_RETIRED_KILLSWITCH_UNIT"
  if ! path_absent "$unit_file"; then
    log "deleting the nft table that the retired $VEKRONA_RETIRED_KILLSWITCH_UNIT loaded"
    printf 'table inet vekrona-vpn\ndelete table inet vekrona-vpn\n' | root nft -f -
  fi
  ensure_system_unit_file_absent "$VEKRONA_RETIRED_KILLSWITCH_UNIT"
}
