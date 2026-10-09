#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
umask 022

work="$(mktemp -d)"
trap 'chmod -R u+rwx "$work"; rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/locked"

# Destinations live in $work/locked, mode 000 like /etc/polkit-1/rules.d is closed to the invoking user. Only the sudo
# stub opens it, for the length of one command, so a check that does not go through `root` sees nothing there.
cat > "$work/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
chmod 700 "$LOCKED"
rc=0
"$@" || rc=$?
chmod 000 "$LOCKED"
exit "$rc"
FAKE
cat > "$work/bin/restorecon" <<'FAKE'
#!/usr/bin/env bash
echo "restorecon $*" >> "$STUB_LOG"
FAKE
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH" LOCKED="$work/locked" STUB_LOG="$work/log"

dst="$LOCKED/lib"
mode_of() { sudo stat -c %a "$dst/$1"; }
tree_src() {
  rm -rf "$work/src"
  mkdir -p "$work/src/sub/deep"
  echo one > "$work/src/a.sh"; chmod 755 "$work/src/a.sh"
  echo two > "$work/src/b.py"
  echo three > "$work/src/sub/deep/c.txt"
  : > "$STUB_LOG"
}
mirror() { ensure_root_tree "$work/src" "$dst" 2>"$work/err"; }

tree_src
mirror
[[ "$(sudo cat "$dst/sub/deep/c.txt")" == three ]] || die "a nested file was not mirrored"
[[ "$(mode_of a.sh) $(mode_of b.py) $(mode_of sub/deep)" == "755 644 755" ]] || die "modes are not exec-bit/0755: $(mode_of a.sh) $(mode_of b.py) $(mode_of sub/deep)"
grep -qx "restorecon -R $dst" "$STUB_LOG" || die "the mirrored tree was not relabeled: $(cat "$STUB_LOG")"
log "ok: a tree is mirrored with directories 0755, the executable bit kept, and SELinux labels restored"

mirror
! grep -q 'installing:\|creating directory\|removing' "$work/err" || die "an unchanged tree was touched again: $(cat "$work/err")"
grep -q "up to date: $dst" "$work/err" || die "an unchanged tree did not report itself up to date"
log "ok: a second run finds a destination that only root can read up to date"

echo changed > "$work/src/b.py"; chmod 755 "$work/src/b.py"; chmod 644 "$work/src/a.sh"
mirror
[[ "$(sudo cat "$dst/b.py")" == changed ]] || die "changed content was not updated"
[[ "$(mode_of b.py) $(mode_of a.sh)" == "755 644" ]] || die "an exec-bit change was not mirrored: $(mode_of b.py) $(mode_of a.sh)"
log "ok: changed content and flipped exec bits are updated"

rm -r "$work/src/sub"; rm "$work/src/a.sh"
sudo sh -c "echo junk > '$dst/stray.txt'; mkdir '$dst/stray-dir'"
mirror
[[ "$(sudo ls -A "$dst")" == b.py ]] || die "files and directories gone from the source were kept: $(sudo ls -A "$dst")"
grep -q "removing: $dst/sub/deep/c.txt" "$work/err" || die "a removal was not logged"
log "ok: files and directories absent from the source are removed, and the removal is logged"

mkdir "$work/src/__pycache__"; echo pyc > "$work/src/__pycache__/x.pyc"
mirror
[[ "$(sudo ls -A "$dst")" == b.py ]] || die "__pycache__ was mirrored"
log "ok: __pycache__ is not part of a tree"

tree_src
ln -s a.sh "$work/src/link"
if (mirror); then die "a symlink in the source was accepted"; fi
grep -q 'cannot mirror' "$work/err" || die "a symlink was refused without saying why: $(cat "$work/err")"
if (ensure_root_tree "$work/nowhere" "$dst") 2>"$work/err"; then die "a missing source directory was accepted"; fi
log "ok: a symlink or a missing source directory is an error"

tree_src
mirror
sudo sh -c "echo drift > '$dst/b.py'"
! root_tree_matches "$work/src" "$dst" || die "a drifted copy matched"
mirror
root_tree_matches "$work/src" "$dst" || die "a drifted copy was not repaired"
log "ok: drift is detected and repaired"

echo file > "$work/f"
f="$LOCKED/rules.d/f"
ensure_root_file "$work/f" "$f" 0644 2>"$work/err"
ensure_root_file "$work/f" "$f" 0644 2>"$work/err"
! grep -q installing "$work/err" || die "a file in a root-only directory was reinstalled although it was current"
ensure_root_file "$work/f" "$f" 0755 2>"$work/err"
[[ "$(sudo stat -c %a "$f")" == 755 ]] || die "a file with the wrong mode was left as it was"
log "ok: ensure_root_file reads root-only destinations and repairs a wrong mode"
