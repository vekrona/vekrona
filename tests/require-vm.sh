# shellcheck shell=bash
# Every shell test entry point calls require_vm "${BASH_SOURCE[0]}" (tests/lib.sh does it for everything that sources it),
# because a test run on the host can fork-bomb it, leave coredumps and write into the real error store. The VM marker is
# what only the vekrona-dev guest has: Lima's boot-done file and the 9p mount of the vekrona-dev checkout.
# The scenarios under tests/e2e and tests/bake-shaders.sh are the exception: they run on the host and drive the guest
# through vekrona-dev, so they pass when vekrona-dev is on PATH (`vekrona-dev e2e` puts it there).
# GitHub Actions' fedora:44 container is the other place: it is a throwaway machine, and the unit-tests job runs tests/run.sh
# there. The Python tests ask this file too (tests/require_vm.py runs it), so the rule lives once.

in_vekrona_dev_guest() {
  [[ -e /run/lima-boot-done ]] && awk '$2 == "/mnt/vekrona-dev" && $3 == "9p" { found = 1 } END { exit !found }' /proc/mounts
}

CONTAINER_MARKERS=(/.dockerenv /run/.containerenv)
in_ci_container() {
  local marker
  [[ "${GITHUB_ACTIONS-}" == true ]] || return 1
  for marker in "${CONTAINER_MARKERS[@]}"; do
    [[ -e "$marker" ]] && return 0
  done
  return 1
}

drives_vekrona_dev_guest() {
  local script
  script="$(readlink -f "$1")"
  case "$script" in
    */tests/e2e/*.sh | */tests/bake-shaders.sh) command -v vekrona-dev >/dev/null ;;
    *) return 1 ;;
  esac
}

require_vm() {
  if in_vekrona_dev_guest || in_ci_container || drives_vekrona_dev_guest "$1"; then
    return 0
  fi
  echo "tests run only in the vekrona-dev VM; see CLAUDE.md" >&2
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then require_vm "${1-}"; fi
