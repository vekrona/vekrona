#!/usr/bin/env bash

find_ovmf() {
  local pair code vars
  local candidates=(
    "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE_4M.fd:/usr/share/edk2/ovmf/OVMF_VARS_4M.fd"
    "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd"
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/edk2-ovmf/OVMF_CODE.fd:/usr/share/edk2-ovmf/OVMF_VARS.fd"
  )
  for pair in "${candidates[@]}"; do
    code="${pair%%:*}"
    vars="${pair##*:}"
    if [[ -r "$code" && -r "$vars" ]]; then
      echo "$code:$vars"
      return 0
    fi
  done
  return 1
}

init_ovmf() {
  local vars_dest="$1" pair
  pair="$(find_ovmf)" || {
    echo "could not find OVMF UEFI firmware (looked for OVMF_CODE*.fd + OVMF_VARS*.fd under /usr/share/edk2/ovmf, /usr/share/OVMF and /usr/share/edk2-ovmf); install edk2-ovmf (Fedora) or ovmf (Debian/Ubuntu)" >&2
    return 1
  }
  cp "${pair##*:}" "$vars_dest"
  echo "${pair%%:*}"
}
