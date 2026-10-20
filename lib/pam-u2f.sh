#!/usr/bin/env bash

# Where pam_u2f reads the registered keys: one root-owned file for every PAM stack (system-auth for sudo, polkit and the
# greeter; the lock screen's own stack). A file in the user's home would be root's source of trust that any process of
# the user can rewrite: it could register its own key and sign in as the user, root included through sudo.
# PIN policy is the same everywhere (pinverification=1 in the PAM files), so credentials need no "+pin" attribute.
U2F_MAPPINGS="${VEKRONA_SYSFS_ROOT:-}/etc/u2f_mappings"

# Where earlier installs, and the installer's VEKRONA SIGN-IN screen, put the registration: no longer read by pam_u2f.
u2f_keys_path() {
  printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/Yubico/u2f_keys"
}

# stdin -> stdout: the lines that register credentials for the user named $1 (user:keyHandle,publicKey,coseType,attributes[:...]).
# A line for any other user would give a process of the user a registration for root's account.
u2f_lines_of_user() {
  awk -v user="$1" 'index($0, user ":") == 1'
}

# Writes the registration into $U2F_MAPPINGS (root:root 0644; the lock screen runs pam_u2f as the user, so it must be
# readable) from the user's old file, once: a file that exists is root's own and is never replaced by the user's.
ensure_u2f_mappings() {
  local legacy lines tmp
  legacy="$(u2f_keys_path)"
  if root test -e "$U2F_MAPPINGS"; then
    log "present: $U2F_MAPPINGS (pam_u2f does not read $legacy)"
    return 0
  fi
  if [[ ! -e "$legacy" ]]; then
    log "no $legacy and no $U2F_MAPPINGS: no security key is registered"
    return 0
  fi
  lines="$(u2f_lines_of_user "$VEKRONA_USER" <"$legacy")" || die "cannot read $legacy"
  if [[ -z "$lines" ]]; then
    warn "$legacy holds no registration for $VEKRONA_USER: nothing to move into $U2F_MAPPINGS"
    return 0
  fi
  tmp="$(root mktemp "$U2F_MAPPINGS.XXXXXX")" || die "cannot create a temp file next to $U2F_MAPPINGS"
  if ! { printf '%s\n' "$lines" | root tee "$tmp" >/dev/null && root chmod 0644 "$tmp" && root mv -f "$tmp" "$U2F_MAPPINGS"; }; then
    root rm -f "$tmp"
    die "cannot write $U2F_MAPPINGS"
  fi
  log "moved the registration of $VEKRONA_USER from $legacy into $U2F_MAPPINGS; pam_u2f reads only that file now"
}
