#!/usr/bin/env bash
# A fake package database with a fake rpm, dnf and sudo in front of PATH (source it after tests/lib.sh; the caller sets $work, a
# scratch directory). One file per installed package in $FAKE_RPMDB; its content is the install reason (empty: Dependency).
# ffmpeg conflicts with the -free libraries. `dnf remove` removes the packages that need a removed package too, and refuses, as dnf
# does, when that takes a protected package (--setopt=protected_packages=a,b) along; glob:/etc/dnf/protected.d/*.conf in that list
# protects sudo. `dnf repoquery --installed --qf` prints
# name|reason lines (the format %{name}|%{reason}\n is the only one it knows).
#   FAKE_DNF_FAIL=1       every dnf call fails
#   FAKE_REPOQUERY_FAIL=1 `dnf repoquery` fails, the other calls work
#   FAKE_DNF_BREAK_ON=PKG the dry run of `dnf remove` of PKG alone fails with an exit status dnf does not use for a refusal
# The dry runs speak French (as dnf does for a person whose LANGUAGE is fr) unless the call has LC_ALL=C.
# `packages NAME...` resets the database to exactly these packages, `installed NAME` asks for one (`all_installed NAME...` for all of them),
# `reason NAME REASON...` sets the install reason (User, Group, ...), `needs HOLDER NEEDED...` makes HOLDER require NEEDED.
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
    protected=""
    for arg in "$@"; do [[ "$arg" == --setopt=protected_packages=* ]] && protected="${arg#--setopt=protected_packages=}"; done
    [[ ",$protected," != *",glob:/etc/dnf/protected.d/*.conf,"* ]] || protected+=",sudo"
    # Everything that goes: the named packages and, transitively, the packages that need one of them.
    declare -A gone=()
    for name in "${names[@]}"; do [[ -e "$FAKE_RPMDB/$name" ]] && gone[$name]=1; done
    changed=1
    while ((changed)); do
      changed=0
      for needs_file in "$FAKE_NEEDS"/*; do
        [[ -e "$needs_file" ]] || continue
        holder="${needs_file##*/}"
        [[ -e "$FAKE_RPMDB/$holder" && -z "${gone[$holder]+x}" ]] || continue
        while IFS= read -r needed; do
          [[ -n "${gone[$needed]+x}" ]] || continue
          gone[$holder]=1
          changed=1
          break
        done < "$needs_file"
      done
    done
    taken=()
    for name in "${!gone[@]}"; do [[ ",$protected," == *",$name,"* ]] && taken+=("$name"); done
    french=0
    [[ -n "${LANGUAGE:-}" && "${LC_ALL:-}" != C ]] && french=1
    if [[ " $* " == *" --assumeno "* && "${#names[@]}" -eq 1 && "${names[0]}" == "${FAKE_DNF_BREAK_ON:-}" ]]; then
      echo "dnf exploded" >&2
      exit 3
    fi
    if ((${#taken[@]})); then
      if ((french)); then
        echo "Problème : L'opération supprimerait les paquets protégés suivants : ${taken[*]}" >&2
      else
        echo "Problem: The operation would result in removing the following protected packages: ${taken[*]}" >&2
      fi
      exit 1
    fi
    if [[ " $* " == *" --assumeno "* ]]; then
      if ((french)); then echo "Opération interrompue par l'utilisateur."; else echo "Operation aborted by the user."; fi
      exit 1
    fi
    for name in "${!gone[@]}"; do rm -f "$FAKE_RPMDB/$name"; done
    ;;
  repoquery)
    [[ -z "${FAKE_REPOQUERY_FAIL:-}" ]] || exit 1
    for pkg_file in "$FAKE_RPMDB"/*; do
      [[ -e "$pkg_file" ]] || continue
      reason="$(<"$pkg_file")"
      echo "${pkg_file##*/}|${reason:-Dependency}"
    done
    ;;
  *) exit 2 ;;
esac
F
write_fake "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
export PATH="$work/bin:$PATH" FAKE_RPMDB="$work/rpmdb" FAKE_NEEDS="$work/needs" FAKE_DNF_LOG="$work/dnf.log"

packages() {
  mkdir -p "$FAKE_RPMDB" "$FAKE_NEEDS"
  rm -f "$FAKE_RPMDB"/* "$FAKE_NEEDS"/* "$FAKE_DNF_LOG"
  local p
  for p in "$@"; do touch "$FAKE_RPMDB/$p"; done
}
installed() { [[ -e "$FAKE_RPMDB/$1" ]]; }
all_installed() { local pkg; for pkg in "$@"; do installed "$pkg" || return 1; done; }
reason() { local pkg="$1"; shift; printf '%s' "$*" > "$FAKE_RPMDB/$pkg"; }
needs() { local holder="$1"; shift; printf '%s\n' "$@" >> "$FAKE_NEEDS/$holder"; }
