#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/etc"

real_mv="$(command -v mv)"
cat > "$work/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
exec "$@"
FAKE
# mv stub: records what the destination held at the instant of the rename (MISSING if nothing); MV_FAIL makes it fail.
cat > "$work/bin/mv" <<FAKE
#!/usr/bin/env bash
[[ -z "\${MV_FAIL-}" ]] || exit 1
dst="\${@: -1}"
{ cat "\$dst" 2>/dev/null || echo MISSING; } > "\$MV_SEEN"
exec "$real_mv" "\$@"
FAKE
# restorecon stub: STALE lists the paths with a wrong label; `-nv` reports them and a plain run repairs them. Every call is logged.
cat > "$work/bin/restorecon" <<'FAKE'
#!/usr/bin/env bash
echo "restorecon $*" >> "$RC_LOG"
if [[ "$1" == -nv ]]; then
  for path in "${@:2}"; do
    while IFS= read -r stale; do [[ "$stale" != "$path" ]] || echo "Would relabel $path"; done <"$STALE"
  done
  exit 0
fi
for path in "$@"; do
  kept=()
  while IFS= read -r stale; do [[ "$stale" == "$path" ]] || kept+=("$stale"); done <"$STALE"
  : >"$STALE"
  for stale in "${kept[@]}"; do echo "$stale" >>"$STALE"; done
done
FAKE
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH" MV_SEEN="$work/mv-seen" RC_LOG="$work/restorecon.log" STALE="$work/stale"
: > "$STALE"

src="$work/src"
dst="$work/etc/sub/file"
mode_of() { stat -c %a "$1"; }
inode_of() { stat -c %i "$1"; }
ensure() { (ensure_root_file "$@") 2>"$work/err" || die "ensure_root_file $* failed: $(<"$work/err")"; }

echo new > "$src"
ensure "$src" "$dst" 0755
[[ "$(<"$dst")" == new && "$(mode_of "$dst")" == 755 ]] || die "a missing file was not installed with its content and mode"
log "ok: a missing file is installed, parent directories included, with the requested mode"

chmod 600 "$dst"
ensure "$src" "$dst" 755
[[ "$(mode_of "$dst")" == 755 ]] || die "a file with the right content and a wrong mode kept its mode"
log "ok: identical content with a wrong mode gets its mode repaired"

inode="$(inode_of "$dst")"
ensure "$src" "$dst" 0755
grep -q 'up to date' "$work/err" || die "an unchanged file was not reported up to date: $(cat "$work/err")"
[[ "$(inode_of "$dst")" == "$inode" ]] || die "an up to date file was rewritten"
log "ok: identical content and mode (0755 or 755) is left alone"

echo old > "$dst"
echo newer > "$src"
ensure "$src" "$dst" 0755
[[ "$(<"$dst")" == newer ]] || die "a changed file was not replaced"
[[ "$(<"$MV_SEEN")" == old ]] || die "the old file was not in place until the rename swapped it: saw $(<"$MV_SEEN")"
log "ok: a changed file is swapped in by rename, so readers never see it missing or partial"

echo older > "$dst"
if (MV_FAIL=1 ensure_root_file "$src" "$dst" 0755) 2>"$work/err"; then die "a failed rename was not reported"; fi
[[ "$(<"$dst")" == older ]] || die "a failed install changed the destination"
[[ "$(ls "$work/etc/sub")" == file ]] || die "a failed install left a temporary file behind: $(ls "$work/etc/sub")"
log "ok: a failed install is an error and leaves the old file and no temporary file"

if (ensure_root_file "$work/nonexistent" "$work/etc/other" 0644) 2>"$work/err"; then die "a missing source was accepted"; fi
grep -q 'source missing' "$work/err" || die "a missing source did not say so: $(cat "$work/err")"
[[ ! -e "$work/etc/other" ]] || die "a missing source still created the destination"
log "ok: a missing source is an error"

dir="$work/etc/labeled"
ensure "$src" "$dir/sub/file" 0644
grep -qx "restorecon $dir/sub $dir" "$RC_LOG" || die "a created directory was not relabeled: $(cat "$RC_LOG")"
grep -qx "restorecon $dir/sub/file $dir/sub" "$RC_LOG" || die "the installed file and its directory were not relabeled: $(cat "$RC_LOG")"
log "ok: the directories an install creates and the file it moves into place are relabeled"

: > "$RC_LOG"
echo "$dir/sub/file" > "$STALE"
inode="$(inode_of "$dir/sub/file")"
ensure "$src" "$dir/sub/file" 0644
[[ ! -s "$STALE" ]] || die "a file with the right content and mode but a wrong label kept its label"
[[ "$(inode_of "$dir/sub/file")" == "$inode" ]] || die "a wrong label was repaired by rewriting the file, which moves its modification time"
log "ok: identical content with a wrong SELinux label gets its label repaired in place"

echo "$dir/sub" > "$STALE"
ensure "$src" "$dir/sub/file" 0644
[[ ! -s "$STALE" ]] || die "a file in a mislabeled directory left the directory mislabeled"
log "ok: a mislabeled directory is repaired on a rerun"

: > "$RC_LOG"
ensure "$src" "$dir/sub/file" 0644
! grep -q '^restorecon [^-]' "$RC_LOG" || die "a file with the right label was relabeled again: $(cat "$RC_LOG")"
log "ok: a file with the right label is left alone"
