# Sourced by fido-keys.sh and u2f-stall-report.sh: the one definition of "a FIDO security key".

# Prints the sysfs path of every hidraw device udev tags ID_FIDO_TOKEN=1.
fido_hidraws() {
  local path props
  for path in /sys/class/hidraw/*; do
    [[ -e "$path" ]] || continue
    if props="$(udevadm info -q property -p "$path")" && grep -qx 'ID_FIDO_TOKEN=1' <<<"$props"; then
      printf '%s\n' "$path"
    fi
  done
}
