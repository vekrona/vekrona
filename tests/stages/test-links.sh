#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# A throwaway HOME, set before lib/common.sh derives the legacy roots from it.
export HOME="$scratch/home"
mkdir -p "$HOME"
source "$REPO/tests/stages/lib.sh"

# The sourced file turned errexit on; the checks below inspect failures themselves.
VEKRONA_ROOT="$HOME/wrk/vekrona"
OLD_CHECKOUT="${VEKRONA_LEGACY_ROOTS[0]}"
OLD_CLONE="${VEKRONA_LEGACY_ROOTS[1]}"
mkdir -p "$VEKRONA_ROOT/config" "$OLD_CHECKOUT/config" "$OLD_CLONE/config"
echo new > "$VEKRONA_ROOT/config/a"
echo new > "$VEKRONA_ROOT/config/b"

# A directory symlinked from outside $HOME's tree is managed elsewhere and left alone.
mkdir -p "$scratch/dotfiles/ghostty" "$HOME/.config"
ln -s "$scratch/dotfiles/ghostty" "$HOME/.config/ghostty"
out="$(ensure_symlink "$VEKRONA_ROOT/config/a" "$HOME/.config/ghostty/config" 2>&1)"
[[ "$out" == *"managed elsewhere"* ]] || die "no 'managed elsewhere' warning: $out"
[[ -z "$(ls -A "$scratch/dotfiles/ghostty")" ]] || die "ensure_symlink wrote into a directory managed elsewhere"
log "ok: a symlinked parent directory is skipped, not written through"

# Same for a deeper symlinked component.
mkdir -p "$scratch/other/sub"
ln -s "$scratch/other" "$HOME/.config/linked"
ensure_symlink "$VEKRONA_ROOT/config/a" "$HOME/.config/linked/sub/x" 2>/dev/null
[[ -z "$(ls -A "$scratch/other/sub")" ]] || die "ensure_symlink wrote through a deeper symlinked component"
log "ok: a symlinked ancestor is skipped too"

# A symlinked $HOME is legitimate: links are still made.
ln -s "$HOME" "$scratch/home-link"
(
  HOME="$scratch/home-link"
  ensure_symlink "$VEKRONA_ROOT/config/a" "$HOME/.config/plain/a" 2>/dev/null
)
[[ -L "$HOME/.config/plain/a" ]] || die "a symlinked \$HOME blocked a normal link"
log "ok: a symlinked HOME does not count as managed elsewhere"

ensure_symlink "$VEKRONA_ROOT/config/a" "$HOME/.config/normal/a" 2>/dev/null
[[ "$(readlink "$HOME/.config/normal/a")" == "$VEKRONA_ROOT/config/a" ]] || die "normal link not created"
log "ok: normal links are created"

# Prune: dangling links into this checkout and any link into a legacy root go; live links into this
# checkout, foreign links and foreign dangling links stay.
d="$HOME/.local/bin"
mkdir -p "$d/sub" "$OLD_CHECKOUT/bin" "$OLD_CLONE/bin"
echo x > "$OLD_CHECKOUT/bin/alive"
echo x > "$OLD_CLONE/bin/alive"
ln -s "$OLD_CHECKOUT/bin/gone" "$d/legacy-dangling"
ln -s "$VEKRONA_ROOT/bin/gone" "$d/new-dangling"
ln -s "$OLD_CHECKOUT/bin/gone" "$d/sub/nested-dangling"
ln -s "$OLD_CHECKOUT/bin/alive" "$d/legacy-alive"
ln -s "$OLD_CLONE/bin/alive" "$d/clone-alive"
ln -s "$VEKRONA_ROOT/config/a" "$d/new-alive"
ln -s "$scratch/nowhere" "$d/foreign-dangling"
ln -s "$OLD_CHECKOUT-other/gone" "$d/lookalike-dangling"
prune_vekrona_links "$d" "$HOME/does-not-exist" 2>/dev/null
for gone in legacy-dangling new-dangling sub/nested-dangling legacy-alive clone-alive; do
  [[ ! -L "$d/$gone" ]] || die "stale vekrona link not pruned: $gone"
done
for kept in new-alive foreign-dangling lookalike-dangling; do
  [[ -L "$d/$kept" ]] || die "link wrongly pruned: $kept"
done
log "ok: prune_vekrona_links removes only stale links into a vekrona root"

# Running from a dev checkout retargets every link into the old clone, and the verify scan sees none left.
mkdir -p "$HOME/.config/sway" "$VEKRONA_ROOT/config/sway"
echo new > "$VEKRONA_ROOT/config/sway/c"
ln -s "$OLD_CLONE/config/sway/c" "$HOME/.config/sway/c"
ensure_symlink "$VEKRONA_ROOT/config/sway/c" "$HOME/.config/sway/c" 2>/dev/null
[[ "$(readlink "$HOME/.config/sway/c")" == "$VEKRONA_ROOT/config/sway/c" ]] || die "a link into the old clone was not retargeted"
rm "$HOME/.config/sway/c"
ln -s "$OLD_CLONE/config/sway/c" "$HOME/.config/sway/c"
[[ "$(vekrona_links "$HOME/.config/sway")" == "$HOME/.config/sway/c" ]] || die "vekrona_links missed a link into the old clone"
is_legacy_link_target "$OLD_CLONE/config/sway/c" || die "the old clone is not legacy while running from elsewhere"
( VEKRONA_ROOT="$OLD_CLONE"; ! is_legacy_link_target "$OLD_CLONE/config/sway/c" ) || die "the tree in use counted as legacy"
rm "$HOME/.config/sway/c"
log "ok: links into the old clone are retargeted and recognised as legacy"

# A symlinked destination dir is somebody else's: not scanned.
ln -s "$VEKRONA_ROOT/bin/gone" "$scratch/other/dangling"
ln -s "$scratch/other" "$HOME/.config/foreign-dir"
prune_vekrona_links "$HOME/.config/foreign-dir" 2>/dev/null
[[ -L "$scratch/other/dangling" ]] || die "pruned inside a symlinked destination dir"
log "ok: a symlinked destination dir is not pruned"

# Ghostty migration: the config link an earlier install made (now dangling) is retired through the
# regular prune; a regular file and a link into somebody's dotfiles stay.
rm -f "$HOME/.config/ghostty"
mkdir -p "$HOME/.config/ghostty"
ln -s "$VEKRONA_ROOT/config/ghostty/config" "$HOME/.config/ghostty/config"
mapfile -t link_dirs < <(vekrona_link_dirs)
prune_vekrona_links "${link_dirs[@]}" 2>/dev/null
[[ ! -L "$HOME/.config/ghostty/config" ]] || die "the dangling vekrona ghostty config link was not retired"
echo mine > "$HOME/.config/ghostty/config"
prune_vekrona_links "${link_dirs[@]}" 2>/dev/null
[[ "$(<"$HOME/.config/ghostty/config")" == mine ]] || die "a regular ghostty config was touched"
rm "$HOME/.config/ghostty/config"
ln -s "$scratch/dotfiles/ghostty-config" "$HOME/.config/ghostty/config"
prune_vekrona_links "${link_dirs[@]}" 2>/dev/null
[[ -L "$HOME/.config/ghostty/config" ]] || die "a dotfiles ghostty config link was removed"
log "ok: only the vekrona ghostty config link is retired"

# install.sh never reaches for the network.
fakebin="$scratch/fakebin"
mkdir -p "$fakebin"
printf '#!/bin/sh\necho "git called: $*" >> %q\nexit 1\n' "$scratch/git.log" > "$fakebin/git"
chmod +x "$fakebin/git"
PATH="$fakebin:$PATH" bash "$REPO/install.sh" --list 00-repos >/dev/null
PATH="$fakebin:$PATH" bash "$REPO/install.sh" --help >/dev/null
[[ ! -e "$scratch/git.log" ]] || die "install.sh --list/--help called git: $(<"$scratch/git.log")"
log "ok: --list and --help never call git"
