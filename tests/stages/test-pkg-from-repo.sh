#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
source "$REPO/tests/lib.sh"

# dnf stub: repoquery --installed prints the repo recorded for the package in $FAKE_FROM (empty output and status 0
# for an absent one, like the real dnf); install --from-repo records it. FAKE_DNF_FAIL makes every call fail.
cat > "$work/bin/dnf" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DNF_LOG"
if [[ -n "${FAKE_DNF_FAIL:-}" ]]; then echo "Failed to download metadata" >&2; exit 1; fi
case "$1" in
  repoquery) cat "$FAKE_FROM/${!#}" 2>/dev/null || true ;;
  install) printf '%s\n' "${3#--from-repo=}" > "$FAKE_FROM/${!#}" ;;
esac
F
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$work/bin/sudo"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" FAKE_FROM="$work/from" FAKE_DNF_LOG="$work/dnf.log"
mkdir "$FAKE_FROM"

: > "$FAKE_DNF_LOG"
ensure_pkg_from_repo rpmfusion-free tool
[[ "$(<"$FAKE_FROM/tool")" == rpmfusion-free ]] || die "an absent package was not installed from the repo"
log "ok: a package that is not installed gets installed from the repo"

: > "$FAKE_DNF_LOG"
ensure_pkg_from_repo rpmfusion-free tool
! grep -q '^install' "$FAKE_DNF_LOG" || die "a package already from the repo was installed again"
log "ok: a package already from the repo is left alone"

: > "$FAKE_DNF_LOG"
if (FAKE_DNF_FAIL=1 ensure_pkg_from_repo rpmfusion-free tool) 2>"$work/err"; then die "a failing dnf repoquery was accepted"; fi
grep -q 'dnf repoquery failed for tool' "$work/err" || die "a failing dnf repoquery did not say so: $(cat "$work/err")"
! grep -q '^install' "$FAKE_DNF_LOG" || die "a failing dnf repoquery was read as 'not installed' and followed by an install"
log "ok: a failing dnf repoquery dies instead of reading as 'not installed'"
