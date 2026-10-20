#!/usr/bin/env bash
# Sanity-flip (VM only): invert the prefix test in links_into_retired_mise_share or drop the post-removal path_absent
# in ensure_root_file_absent / ensure_root_tree_absent, and the matching case below must fail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/noop-bin"

cat > "$work/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
exec "$@"
FAKE
# A sudo that succeeds without removing anything, as a rm that silently did nothing would.
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/noop-bin/sudo"
chmod +x "$work/bin"/* "$work/noop-bin"/*
export PATH="$work/bin:$PATH"

absent_file() { (ensure_root_file_absent "$1") 2>"$work/err"; }
absent_tree() { (ensure_root_tree_absent "$1") 2>"$work/err"; }

ln -s "$work/nowhere" "$work/dangling"
absent_file "$work/dangling"
[[ ! -L "$work/dangling" ]] || die "a dangling symlink was left in place"
log "ok: a dangling symlink is removed as a file"

echo x > "$work/file"
absent_file "$work/file"
[[ ! -e "$work/file" ]] || die "a regular file was left in place"
absent_file "$work/file"
grep -q "absent: $work/file" "$work/err" || die "a missing file was not reported absent: $(cat "$work/err")"
log "ok: a regular file is removed and a missing one is a no-op"

mkdir -p "$work/tree/sub/deep"
echo x > "$work/tree/sub/deep/f"
absent_tree "$work/tree"
[[ ! -e "$work/tree" ]] || die "a tree was left in place"
log "ok: a tree is removed with everything below it"

absent_tree "$work/tree"
grep -q "absent: $work/tree" "$work/err" || die "a missing tree was not reported absent: $(cat "$work/err")"
log "ok: a missing tree is a no-op"

mkdir "$work/target"
echo precious > "$work/target/f"
ln -s "$work/target" "$work/link"
if absent_tree "$work/link"; then die "a symlink to a directory was accepted"; fi
[[ -L "$work/link" && "$(<"$work/target/f")" == precious ]] || die "refusing a symlink still touched it or its target"
ln -s "$work/nowhere" "$work/dangling-tree"
if absent_tree "$work/dangling-tree"; then die "a dangling symlink was accepted as a tree"; fi
[[ -L "$work/dangling-tree" ]] || die "refusing a dangling symlink still removed it"
log "ok: a symlink is refused and neither it nor its target is touched"

echo x > "$work/regular"
if absent_tree "$work/regular"; then die "a regular file was accepted as a tree"; fi
[[ -f "$work/regular" ]] || die "refusing a regular file still removed it"
log "ok: a regular file is refused"

echo x > "$work/stuck"
if (PATH="$work/noop-bin:$PATH" ensure_root_file_absent "$work/stuck") 2>"$work/err"; then die "a file that survived the removal was accepted"; fi
grep -q "failed to remove $work/stuck" "$work/err" || die "a surviving file was not reported: $(cat "$work/err")"
[[ -f "$work/stuck" ]] || die "the noop sudo removed the file, the test proves nothing"
log "ok: a file that survives its removal fails the call"

mkdir "$work/stuck-tree"
if (PATH="$work/noop-bin:$PATH" ensure_root_tree_absent "$work/stuck-tree") 2>"$work/err"; then die "a tree that survived the removal was accepted"; fi
grep -q "failed to remove $work/stuck-tree" "$work/err" || die "a surviving tree was not reported: $(cat "$work/err")"
[[ -d "$work/stuck-tree" ]] || die "the noop sudo removed the tree, the test proves nothing"
log "ok: a tree that survives its removal fails the call"

share="$work/mise-share"
VEKRONA_RETIRED_MISE_SHARE="$share"
mkdir -p "$share/bin" "${share}x/bin" "$work/elsewhere"
echo x > "$share/bin/tool"
echo x > "$work/regular-file"
ln -s "$share/bin/tool" "$work/into-share"
ln -s "$share/bin/gone" "$work/into-share-dangling"
ln -s "$work/elsewhere" "$work/elsewhere-link"
ln -s "${share}x/bin" "$work/prefix-sibling"
links_into_retired_mise_share "$work/into-share" || die "a symlink into the share was not recognised"
links_into_retired_mise_share "$work/into-share-dangling" || die "a dangling symlink into the share was not recognised"
log "ok: a symlink into the share is recognised, dangling or not"

for not_a_link in "$work/regular-file" "$share/bin/tool" "$work/elsewhere-link" "$work/prefix-sibling" "$work/missing"; do
  if links_into_retired_mise_share "$not_a_link"; then die "$not_a_link was taken for a link into the share"; fi
done
log "ok: a regular file, a link elsewhere, a link to a string-prefix sibling and a missing path are not links into the share"
