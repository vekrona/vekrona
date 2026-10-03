#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
source "$REPO/tests/stages/lib.sh"

# A fake package database: one file per installed package. ffmpeg conflicts with the -free libraries.
cat > "$work/bin/rpm" <<'F'
#!/usr/bin/env bash
[[ "$1" == -q && -e "$FAKE_RPMDB/$2" ]]
F
cat > "$work/bin/dnf" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DNF_LOG"
[[ -z "${FAKE_DNF_FAIL:-}" ]] || exit 1
allow_erasing=0
[[ " $* " == *" --allowerasing "* ]] && allow_erasing=1
conflicts() { compgen -G "$FAKE_RPMDB/*-free" >/dev/null; }
names=()
for arg in "${@:2}"; do [[ "$arg" == -* ]] || names+=("$arg"); done
case "$1" in
  install)
    if conflicts; then
      ((allow_erasing)) || { echo "conflicting requests" >&2; exit 1; }
      rm -f "$FAKE_RPMDB"/*-free
    fi
    touch "$FAKE_RPMDB/${names[-1]}"
    ;;
  swap)
    rm -f "$FAKE_RPMDB/${names[0]}" "$FAKE_RPMDB"/*-free
    touch "$FAKE_RPMDB/${names[1]}"
    ;;
  *) exit 2 ;;
esac
F
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$work/bin/sudo"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" FAKE_RPMDB="$work/rpmdb" FAKE_DNF_LOG="$work/dnf.log"

packages() { mkdir -p "$FAKE_RPMDB"; rm -f "$FAKE_RPMDB"/* "$FAKE_DNF_LOG"; local p; for p in "$@"; do touch "$FAKE_RPMDB/$p"; done; }
installed() { [[ -e "$FAKE_RPMDB/$1" ]]; }

packages libswscale-free libavcodec-free
ensure_pkg_swapped ffmpeg-free ffmpeg
installed ffmpeg || die "ffmpeg must replace the free ffmpeg libraries even without the ffmpeg-free package"
! installed libswscale-free || die "the conflicting free library must be gone"
log "ok: free ffmpeg libraries alone are replaced"

packages ffmpeg-free libswscale-free
ensure_pkg_swapped ffmpeg-free ffmpeg
installed ffmpeg && ! installed ffmpeg-free || die "ffmpeg-free must be swapped for ffmpeg"
log "ok: ffmpeg-free is swapped"

packages
ensure_pkg_swapped ffmpeg-free ffmpeg
installed ffmpeg || die "ffmpeg must be installed on a system without any free variant"
log "ok: a clean system gets ffmpeg"

packages ffmpeg
ensure_pkg_swapped ffmpeg-free ffmpeg
[[ ! -e "$FAKE_DNF_LOG" ]] || die "an already swapped system must not touch dnf: $(cat "$FAKE_DNF_LOG")"
log "ok: an already swapped system is left alone"

packages libswscale-free
if (FAKE_DNF_FAIL=1 ensure_pkg_swapped ffmpeg-free ffmpeg); then
  die "a failing dnf must fail the swap"
fi
log "ok: a failing dnf fails the swap"
