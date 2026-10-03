#!/usr/bin/env bash

# PIN policy lives in the PAM files (pinverification=), never in the
# credential: a "+pin" attribute in u2f_keys makes pam_u2f demand the PIN
# even where the PAM file says pinverification=0 (the touch-only lock screen).

u2f_keys_path() {
  printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/Yubico/u2f_keys"
}

# stdin -> stdout: drops the exact "+pin" flag from the attributes field of
# every credential (user:keyHandle,publicKey,coseType,attributes:...), every
# other byte stays.
u2f_keys_without_pin_flag() {
  perl -pe 's{(,[^,:\n]*,[^,:\n]*,)([^,:\n]*)}{$1 . join("", grep { $_ ne "+pin" } split(/(?=\+)/, $2))}ge'
}

u2f_keys_have_pin_flag() {
  local file="$1"
  ! u2f_keys_without_pin_flag <"$file" | cmp -s - "$file"
}

ensure_u2f_keys_without_pin_flag() {
  local file tmp
  file="$(u2f_keys_path)"
  if [[ ! -e "$file" ]]; then
    log "no $file, nothing to migrate"
    return 0
  fi
  file="$(readlink -f "$file")"
  if ! u2f_keys_have_pin_flag "$file"; then
    log "$file carries no +pin flag"
    return 0
  fi
  tmp="$(mktemp "$file.XXXXXX")" || die "cannot create a temp file next to $file"
  if ! { u2f_keys_without_pin_flag <"$file" >"$tmp" && chmod --reference="$file" "$tmp" && mv -f "$tmp" "$file"; }; then
    rm -f "$tmp"
    die "cannot rewrite $file"
  fi
  log "removed the +pin flag from $file (PIN policy comes from the PAM files)"
}
