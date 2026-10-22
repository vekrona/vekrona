#!/usr/bin/env bash

# stdin -> stdout: the geoclue app config with the users it lists set to the one uid UID. The shipped file leaves users=
# empty, which geoclue reads as "every user may use this app".
render_geoclue_conf() {
  local uid="$1"
  [[ "$uid" =~ ^[0-9]+$ ]] || die "not a uid: $uid"
  awk -v uid="$uid" '
    /^users=/ { print "users=" uid; found = 1; next }
    { print }
    END { if (!found) exit 1 }'
}
