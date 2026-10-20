#!/usr/bin/env bash

# stdin -> stdout: the xremap.path unit for the user with uid UID.
render_xremap_path_unit() {
  local uid="$1"
  [[ "$uid" =~ ^[0-9]+$ ]] || die "not a uid: $uid"
  sed "s/@UID@/$uid/g"
}

# Installs xremap.path for the user this install is for, from a rendered copy.
install_xremap_path_unit() {
  local scratch="$1"
  render_xremap_path_unit "$(id -u)" <"$VEKRONA_ROOT/etc/systemd/system/xremap.path" >"$scratch/xremap.path"
  ! grep -q '@UID@' "$scratch/xremap.path" || die "xremap.path still has a placeholder"
  ensure_system_unit_file "$scratch/xremap.path"
}
