#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/volume"

# A directory is a subvolume while it holds .is-subvolume: stat then reports btrfs (STAT_FSTYPE) and inode 256, like the root of a
# real subvolume, and any other directory inode 257. STAT_ERROR makes stat fail like one refused by the kernel. The top-level volume
# is mounted while its directory holds .mounted, and unmounting empties the directory. A mount of /tmp is only logged, so that no test mounts over the VM's real /tmp.
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }
stub sudo 'exec "$@"'
stub chown 'echo "chown $*" >> "$STUB_LOG"'
stub restorecon 'echo "restorecon $*" >> "$STUB_LOG"'
stub chcon 'echo "chcon $*" >> "$STUB_LOG"'
stub matchpathcon 'echo system_u:object_r:tmp_t:s0'
stub selinuxenabled '[[ -z "${SELINUX_OFF-}" ]]'
stub systemctl 'echo "systemctl $*" >> "$STUB_LOG"'
stub btrfs 'echo "btrfs $*" >> "$STUB_LOG"
case "$2" in
  create) mkdir "$3" && touch "$3/.is-subvolume" ;;
  *) exit 99 ;;
esac'
stub stat 'if [[ -n "${STAT_ERROR-}" ]]; then echo "stat: cannot statx ${*: -1}: Permission denied" >&2; exit 1; fi
case "$1" in
  -f) echo "${STAT_FSTYPE-btrfs}" ;;
  -c) if [[ -e "${*: -1}/.is-subvolume" ]]; then echo 256; else echo 257; fi ;;
  *) exit 99 ;;
esac'
# findmnt answers FINDMNT_ANSWER as the source and FINDMNT_FSTYPE as the type of every path but /, which is on the btrfs device.
stub findmnt 'if [[ "$3" == / ]]; then echo "/dev/vda3[/root]"; exit 0; fi
case "$2" in
  SOURCE) answer="${FINDMNT_ANSWER-}" ;;
  FSTYPE) answer="${FINDMNT_FSTYPE-}" ;;
  *) exit 99 ;;
esac
echo "$answer"; [[ -n "$answer" ]]'
stub mount 'echo "mount $*" >> "$STUB_LOG"; if [[ "$1" == -o ]]; then touch "${*: -1}/.mounted"; fi'
stub umount 'echo "umount $*" >> "$STUB_LOG"; find "$1" -mindepth 1 -delete'
stub mountpoint '[[ -e "$2/.mounted" || ( "$2" == /tmp && -n "${TMP_MOUNTED-}" ) ]]'
# Every chmod is recorded; only the one of /tmp itself is not carried out.
real_chmod="$(command -v chmod)"
stub chmod 'echo "chmod $*" >> "$STUB_LOG"; if [[ "${*: -1}" != /tmp ]]; then exec '"$real_chmod"' "$@"; fi'
export PATH="$work/bin:$PATH" STUB_LOG="$work/log"
VEKRONA_FSTAB="$work/fstab"
: > "$STUB_LOG"
calls() { grep -c "^$1 " "$STUB_LOG" || [[ $? -eq 1 ]]; }

HOME_LINE='UUID=abc /home btrfs subvol=home,compress=zstd:1 0 0'
[[ "$(retarget_fstab_line "$HOME_LINE" /tmp tmp)" == 'UUID=abc /tmp btrfs subvol=tmp,compress=zstd:1 0 0' ]] \
  || die "the subvolume and the mount point were not swapped"
[[ "$(retarget_fstab_line "$HOME_LINE" /tmp tmp nodev,nosuid)" == 'UUID=abc /tmp btrfs subvol=tmp,compress=zstd:1,nodev,nosuid 0 0' ]] \
  || die "the extra options were not appended"
log "ok: a retargeted fstab line swaps subvolume and mount point and appends the extra options"

for line in 'UUID=abc /home btrfs compress=zstd:1 0 0' 'UUID=abc /home btrfs subvol=home,subvol=other 0 0'; do
  if (retarget_fstab_line "$line" /tmp tmp) 2>/dev/null; then die "a line without exactly one subvol= was retargeted: $line"; fi
done
log "ok: a line with no subvol= option, or two, is an error"

FINDMNT_ANSWER='/dev/vda3[/tmp]' btrfs_subvolume_mounted /tmp tmp || die "a mount from subvolume tmp was not recognised"
for answer in '/dev/vda3[/tmpfoo]' '/dev/vda3[/home]' 'tmpfs' ''; do
  if FINDMNT_ANSWER="$answer" btrfs_subvolume_mounted /tmp tmp; then die "'$answer' was taken for a mount from subvolume tmp"; fi
done
log "ok: only a mount from exactly that subvolume counts, and an unmounted path does not"

ensure_btrfs_subvolume tmp "$work/volume" 2>/dev/null
[[ -e "$work/volume/tmp/.is-subvolume" ]] || die "the subvolume was not created"
ensure_btrfs_subvolume tmp "$work/volume" 2>/dev/null
[[ "$(grep -c '^btrfs subvolume create' "$STUB_LOG")" -eq 1 ]] || die "an existing subvolume was created again"
log "ok: a subvolume is created once"

mkdir "$work/volume/plain"
if (ensure_btrfs_subvolume plain "$work/volume") 2>/dev/null; then die "a plain directory was taken for a subvolume"; fi
log "ok: a plain directory in the place of the subvolume is an error"

mkdir "$work/volume/ext"
touch "$work/volume/ext/.is-subvolume"
if (STAT_FSTYPE=ext4 ensure_btrfs_subvolume ext "$work/volume") 2>/dev/null; then die "inode 256 on a filesystem other than btrfs was taken for a subvolume"; fi
log "ok: only a btrfs directory with inode 256 is a subvolume"

mkdir "$work/volume/unreadable"
: > "$STUB_LOG"
if out="$(STAT_ERROR=1 ensure_btrfs_subvolume unreadable "$work/volume" 2>&1)"; then die "a path that could not be examined was accepted"; fi
[[ "$out" == *"Permission denied"* ]] || die "the cause of the failed examination was not reported: $out"
[[ "$out" != *"not a btrfs subvolume"* ]] || die "a failed examination was reported as 'not a subvolume': $out"
[[ "$(calls btrfs)" -eq 0 ]] || die "a subvolume was created over a path that could not be examined"
log "ok: a path that cannot be examined stops with the real cause instead of reading as no subvolume"

: > "$STUB_LOG"
used="$work/used"
record_top() { echo "$1" > "$used"; [[ -e "$1/.mounted" ]]; }
with_btrfs_top_level record_top 2>/dev/null || die "the command did not see the top-level volume mounted"
[[ "$(calls umount)" -eq 1 && ! -e "$(<"$used")" ]] || die "the top-level volume stayed mounted or its directory stayed after the command"
log "ok: the top-level volume is mounted for the command and unmounted afterwards"

: > "$STUB_LOG"
fail_in_top() { echo "$1" > "$used"; return 1; }
if with_btrfs_top_level fail_in_top 2>/dev/null; then die "a failing command was reported as success"; fi
[[ "$(calls umount)" -eq 1 && ! -e "$(<"$used")" ]] || die "a failing command left the top-level volume mounted"
log "ok: a failing command still gets the top-level volume unmounted"

mkdir "$work/top"
: > "$STUB_LOG"
ensure_tmp_subvolume_root "$work/top" 2>/dev/null
find "$work/top/tmp" -maxdepth 0 -perm 1777 | grep -q . || die "the new tmp subvolume is not mode 1777, so users cannot write /tmp after the next boot"
grep -qx "chown root:root $work/top/tmp" "$STUB_LOG" || die "the new tmp subvolume was not given to root"
grep -qx "chcon system_u:object_r:tmp_t:s0 $work/top/tmp" "$STUB_LOG" || die "the new tmp subvolume got no tmp_t label: $(<"$STUB_LOG")"
log "ok: a new tmp subvolume is root's, mode 1777 and labeled tmp_t before it is ever mounted"

chmod 0700 "$work/top/tmp"
ensure_tmp_subvolume_root "$work/top" 2>/dev/null
find "$work/top/tmp" -maxdepth 0 -perm 1777 | grep -q . || die "a tmp subvolume whose mode drifted was not made 1777 again"
log "ok: a tmp subvolume whose mode drifted is made 1777 again"

: > "$STUB_LOG"
SELINUX_OFF=1 ensure_tmp_subvolume_root "$work/top" 2>/dev/null
if grep -q '^chcon ' "$STUB_LOG"; then die "a label was set although SELinux is off"; fi
log "ok: with SELinux off the subvolume root gets no label"

# ensure_tmp_subvolume against a scratch fstab that holds /home's line. A running tmpfs /tmp is TMP_MOUNTED with FINDMNT_FSTYPE=tmpfs,
# a /tmp that is a plain directory is neither.
TMP_LINE='UUID=abc /tmp btrfs subvol=tmp,compress=zstd:1,nodev,nosuid 0 0'
fresh_fstab() { echo "$HOME_LINE" > "$VEKRONA_FSTAB"; : > "$STUB_LOG"; }
fstab_is() { [[ "$(<"$VEKRONA_FSTAB")" == "$1" ]]; }
tmp_mounted() { grep -qx 'mount /tmp' "$STUB_LOG"; }
tmp_chmodded() { grep -qx 'chmod 1777 /tmp' "$STUB_LOG"; }
# The subvolume root is made 1777 through the path under the top-level mount, never through /tmp.
subvolume_root_made_1777() { grep -qE '^chmod 1777 .+/tmp$' "$STUB_LOG"; }
NEW_FSTAB="$HOME_LINE"$'\n'"$TMP_LINE"

fresh_fstab
TMP_MOUNTED=1 FINDMNT_ANSWER=tmpfs FINDMNT_FSTYPE=tmpfs ensure_tmp_subvolume 2>/dev/null
subvolume_root_made_1777 || die "the tmp subvolume was not made 1777 for the next boot: $(<"$STUB_LOG")"
fstab_is "$NEW_FSTAB" || die "a tmpfs /tmp got no fstab line for the subvolume: $(<"$VEKRONA_FSTAB")"
if tmp_mounted || tmp_chmodded; then die "a running tmpfs /tmp was mounted over or chmod-ed: $(<"$STUB_LOG")"; fi
log "ok: a running tmpfs /tmp gets the fstab line but stays as it is until the next boot"

fresh_fstab
ensure_tmp_subvolume 2>/dev/null
subvolume_root_made_1777 || die "the tmp subvolume was not made 1777 for the next boot: $(<"$STUB_LOG")"
fstab_is "$NEW_FSTAB" || die "a plain /tmp directory got no fstab line for the subvolume: $(<"$VEKRONA_FSTAB")"
if tmp_mounted || tmp_chmodded; then die "a plain /tmp directory was mounted over or chmod-ed, which hides the files of running programs: $(<"$STUB_LOG")"; fi
log "ok: a plain /tmp directory gets the fstab line but is not mounted over until the next boot"

fresh_fstab
echo "$TMP_LINE" >> "$VEKRONA_FSTAB"
TMP_MOUNTED=1 FINDMNT_ANSWER='/dev/vda3[/tmp]' FINDMNT_FSTYPE=btrfs ensure_tmp_subvolume 2>/dev/null
fstab_is "$NEW_FSTAB" || die "the fstab of a /tmp already on the subvolume changed: $(<"$VEKRONA_FSTAB")"
if tmp_mounted; then die "a /tmp already on the subvolume was mounted again"; fi
if tmp_chmodded; then die "a /tmp already on the subvolume was chmod-ed through /tmp"; fi
log "ok: a /tmp already on the subvolume is not mounted again"

fresh_fstab
if out="$(TMP_MOUNTED=1 FINDMNT_ANSWER=/dev/sdb1 FINDMNT_FSTYPE=ext4 ensure_tmp_subvolume 2>&1)"; then die "a /tmp mounted from another device was accepted"; fi
[[ "$out" == *"/dev/sdb1"* ]] || die "the foreign /tmp mount was not named in the error: $out"
fstab_is "$HOME_LINE" || die "an fstab line was written for a /tmp that is mounted from another device"
if tmp_mounted; then die "a /tmp mounted from another device was mounted over"; fi
if grep -q '^btrfs subvolume create' "$STUB_LOG"; then die "a tmp subvolume was created for a /tmp that is mounted from another device: $(<"$STUB_LOG")"; fi
log "ok: a /tmp mounted from anything else is an error that leaves fstab, the mount and the volume alone"
