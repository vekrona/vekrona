#!/usr/bin/env bash

CRYPTTAB=/etc/crypttab
LUKS_FIDO2_OPTIONS=(fido2-device=auto token-timeout=10s)

initramfs_path_for() { printf '/boot/initramfs-%s.img' "$1"; }

read_crypttab() {
  [[ -e "$CRYPTTAB" ]] || return 0
  root cat "$CRYPTTAB" || die "cannot read $CRYPTTAB"
}

kvers_with_initramfs() {
  local all kver
  all="$(installed_kvers)" || die "cannot list installed kernels"
  while IFS= read -r kver; do
    if [[ -n "$kver" && -f "$(initramfs_path_for "$kver")" ]]; then
      printf '%s\n' "$kver"
    fi
  done <<<"$all"
}

resolve_crypttab_device() {
  case "$1" in
    UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*) findfs "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

crypttab_luks2_entries() {
  local content="$1" name device keyfile rest dev
  while read -r name device keyfile rest; do
    if [[ -z "$name" || "$name" == \#* ]]; then
      continue
    fi
    if [[ "$keyfile" == /dev/urandom || "$keyfile" == /dev/random ]]; then
      log "skipping crypttab entry $name: random-key device"
      continue
    fi
    if ! dev="$(resolve_crypttab_device "$device")" || [[ ! -e "$dev" ]]; then
      log "skipping crypttab entry $name: device not present ($device)"
      continue
    fi
    if ! root cryptsetup isLuks --type luks2 "$dev"; then
      log "skipping crypttab entry $name: $dev is not LUKS2"
      continue
    fi
    printf '%s\t%s\n' "$name" "$dev"
  done <<<"$content"
}

luks_device_has_fido2_token() {
  local metadata
  metadata="$(root cryptsetup luksDump --dump-json-metadata "$1")" || die "cryptsetup luksDump failed for $1"
  jq -e '[.tokens[]? | select(.type == "systemd-fido2")] | length > 0' <<<"$metadata" >/dev/null
}

crypttab_fido2_tokens() {
  local content="$1" entries name dev state
  entries="$(crypttab_luks2_entries "$content")" || die "cannot enumerate LUKS2 crypttab entries"
  while IFS=$'\t' read -r name dev; do
    if [[ -z "$name" ]]; then
      continue
    fi
    if luks_device_has_fido2_token "$dev"; then state=yes; else state=no; fi
    printf '%s\t%s\t%s\n' "$name" "$dev" "$state"
  done <<<"$entries"
}

merged_crypttab_options() {
  local existing="$1" merged="$1" want key
  if [[ "$existing" == none || "$existing" == - ]]; then
    merged=""
  fi
  for want in "${LUKS_FIDO2_OPTIONS[@]}"; do
    key="${want%%=*}"
    if [[ ",$merged," == *",$key="* ]]; then
      continue
    fi
    merged="${merged:+$merged,}$want"
  done
  printf '%s' "$merged"
}

crypttab_with_fido2() {
  local content="$1" line name device keyfile options n
  shift
  while IFS= read -r line; do
    read -r name device keyfile options _ <<<"$line"
    if [[ -n "$name" && "$name" != \#* ]]; then
      for n in "$@"; do
        if [[ "$n" == "$name" ]]; then
          line="$name $device ${keyfile:-none} $(merged_crypttab_options "${options:-none}")"
        fi
      done
    fi
    printf '%s\n' "$line"
  done <<<"$content"
}

crypttab_line_has_fido2() {
  local content="$1" name="$2" line
  line="$(grep -E "^${name}[[:space:]]" <<<"$content")" || return 1
  [[ "$line" == *fido2-device=* ]]
}

initramfs_has_fido2() {
  local listing
  listing="$(root lsinitrd "$(initramfs_path_for "$1")")" || die "lsinitrd failed for kernel $1"
  [[ "$listing" == *fido2* ]]
}

initramfs_crypttab_has_fido2() {
  local content
  content="$(root lsinitrd -f etc/crypttab "$(initramfs_path_for "$1")")" || die "lsinitrd failed for kernel $1"
  [[ "$content" == *fido2-device=* ]]
}

initramfs_carries_fido2() {
  initramfs_has_fido2 "$1" || return 1
  initramfs_crypttab_has_fido2 "$1"
}
