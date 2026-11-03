#!/usr/bin/env bash
# A fake package database with a fake rpm, dnf and sudo in front of PATH (source it after tests/lib.sh; the caller sets $work, a
# scratch directory). One file per installed package in $FAKE_RPMDB. ffmpeg conflicts with the -free libraries.
#   FAKE_DNF_FAIL=1       every dnf call fails
#   FAKE_DNF_PROTECTED=1  the dry run of `dnf remove` refuses, as dnf does for a protected package
# `packages NAME...` resets the database to exactly these packages, `installed NAME` asks for one.
: "${work:?source dnf-fakes.sh with \$work set to a scratch directory}"
mkdir -p "$work/bin"
# rpm -q answers the two queries wlroots_package_name asks about sway; any other name is a package.
write_fake "$work/bin/rpm" <<'F'
#!/usr/bin/env bash
case "$*" in
  "-q --requires sway") echo "libwlroots-0.19.so()(64bit)"; exit 0 ;;
  "-q --whatprovides "*" --qf "*) echo wlroots0.19; exit 0 ;;
esac
[[ "$1" == -q && -e "$FAKE_RPMDB/$2" ]]
F
write_fake "$work/bin/dnf" <<'F'
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
  remove)
    if [[ " $* " == *" --assumeno "* ]]; then
      if [[ -n "${FAKE_DNF_PROTECTED:-}" ]]; then
        echo "Problem: The operation would result in removing the following protected packages: sway" >&2
      else
        echo "Operation aborted by the user."
      fi
      exit 1
    fi
    for name in "${names[@]}"; do rm -f "$FAKE_RPMDB/$name"; done
    ;;
  *) exit 2 ;;
esac
F
write_fake "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
export PATH="$work/bin:$PATH" FAKE_RPMDB="$work/rpmdb" FAKE_DNF_LOG="$work/dnf.log"

packages() { mkdir -p "$FAKE_RPMDB"; rm -f "$FAKE_RPMDB"/* "$FAKE_DNF_LOG"; local p; for p in "$@"; do touch "$FAKE_RPMDB/$p"; done; }
installed() { [[ -e "$FAKE_RPMDB/$1" ]]; }
