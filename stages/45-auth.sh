#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/authselect-vekrona.sh"
source "$ROOT/lib/luks-fido2.sh"

require_cmd authselect cryptsetup dracut lsinitrd jq findfs

PROFILE_NAME=vekrona
PROFILE_ID="custom/$PROFILE_NAME"
PROFILE_DIR="/etc/authselect/custom/$PROFILE_NAME"
PROFILE_FEATURES=(with-silent-lastlog with-fingerprint with-mdns4 with-pam-u2f)

ensure_pkg pam-u2f pamu2fcfg fido2-tools libfido2 fprintd fprintd-pam

render_profile() {
  render_authselect_profile "$(authselect_base_dir)" "$1"
}

install_profile() {
  local rendered="$1" f
  root rm -rf "$PROFILE_DIR"
  root install -d -m 0755 "$PROFILE_DIR"
  for f in "$rendered"/*; do
    root install -m 0644 "$f" "$PROFILE_DIR/$(basename "$f")"
  done
  root diff -r "$rendered" "$PROFILE_DIR" >/dev/null || die "profile content mismatch after install: $PROFILE_DIR"
}

ensure_profile_files() {
  local rendered
  rendered="$(mktemp -d)"
  render_profile "$rendered"
  if [[ -d "$PROFILE_DIR" ]] && root diff -r "$rendered" "$PROFILE_DIR" >/dev/null; then
    log "authselect profile up to date: $PROFILE_ID"
    profile_files_changed=0
  else
    log "writing authselect profile: $PROFILE_ID"
    install_profile "$rendered"
    profile_files_changed=1
  fi
  rm -rf "$rendered"
}

current_authselect_selection() {
  local raw
  raw="$(authselect current --raw 2>/dev/null || true)"
  tr ' ' '\n' <<<"$raw" | sed '/^$/d' | sort | paste -sd' '
}

wanted_authselect_selection() {
  printf '%s\n' "$PROFILE_ID" "${PROFILE_FEATURES[@]}" | sort | paste -sd' '
}

previous_profile_id() {
  local raw
  raw="$(authselect current --raw 2>/dev/null || true)"
  printf '%s' "${raw%% *}"
}

ensure_authselect_selection() {
  local previous
  previous="$(previous_profile_id)"
  ensure_profile_files
  if [[ "$(current_authselect_selection)" == "$(wanted_authselect_selection)" ]]; then
    if [[ "$profile_files_changed" -eq 1 ]]; then
      log "reapplying authselect profile after content change"
      root authselect apply-changes
    else
      log "authselect already selects $PROFILE_ID with: ${PROFILE_FEATURES[*]}"
    fi
  else
    log "selecting $PROFILE_ID with: ${PROFILE_FEATURES[*]}"
    root authselect select "$PROFILE_ID" "${PROFILE_FEATURES[@]}"
    if [[ "$previous" == custom/yubikey ]]; then
      warn "pam_u2f origin changed from the hostname to pam://vekrona: re-register your key once with:"
      warn "  mkdir -p ~/.config/Yubico && pamu2fcfg -N -o pam://vekrona -i pam://vekrona > ~/.config/Yubico/u2f_keys"
    fi
  fi
  [[ "$(current_authselect_selection)" == "$(wanted_authselect_selection)" ]] || die "authselect selection not applied: $PROFILE_ID"
  root authselect check || die "authselect check failed"
}

rebuild_initramfs() {
  local kver="$1" img
  img="$(initramfs_path_for "$kver")"
  root cp -p "$img" "$img.bak"
  log "rebuilding initramfs for $kver (rollback: sudo cp -p $img.bak $img)"
  root dracut -f "$img" "$kver"
}

install_crypttab() {
  local out
  out="$(mktemp)"
  printf '%s\n' "$1" >"$out"
  root install -m 0644 "$out" "$CRYPTTAB"
  rm -f "$out"
}

ensure_luks_fido2_unlock() {
  local entries name dev state kver kvers crypttab_changed=0 current wanted
  local -a token_names=()
  current="$(read_crypttab)"
  entries="$(crypttab_fido2_tokens "$current")"
  while IFS=$'\t' read -r name dev state; do
    if [[ -z "$name" ]]; then
      continue
    fi
    if [[ "$state" == yes ]]; then
      log "FIDO2 token present on $dev ($name)"
      token_names+=("$name")
    else
      log "no FIDO2 token on $dev ($name)"
    fi
  done <<<"$entries"

  if [[ ${#token_names[@]} -eq 0 ]]; then
    log "no LUKS2 device with a systemd-fido2 token, crypttab and initramfs left alone"
    return 0
  fi

  wanted="$(crypttab_with_fido2 "$current" "${token_names[@]}")"
  if [[ "$wanted" != "$current" ]]; then
    log "adding fido2-device to crypttab for: ${token_names[*]}"
    install_crypttab "$wanted"
    crypttab_changed=1
  else
    log "crypttab already carries fido2-device for: ${token_names[*]}"
  fi

  kvers="$(kvers_with_initramfs)"
  [[ -n "$kvers" ]] || die "no installed kernel has an initramfs"
  while IFS= read -r kver; do
    if [[ "$crypttab_changed" -eq 1 ]] || ! initramfs_carries_fido2 "$kver"; then
      rebuild_initramfs "$kver"
    else
      log "initramfs for $kver already carries FIDO2 unlock"
    fi
  done <<<"$kvers"

  current="$(read_crypttab)"
  for name in "${token_names[@]}"; do
    assert "crypttab entry $name has fido2-device" crypttab_line_has_fido2 "$current" "$name"
  done
  while IFS= read -r kver; do
    assert "initramfs for $kver carries FIDO2 unlock" initramfs_carries_fido2 "$kver"
  done <<<"$kvers"
}

ensure_authselect_selection
ensure_luks_fido2_unlock
ensure_root_file "$ROOT/etc/pam.d/dankshell-u2f" /etc/pam.d/dankshell-u2f
