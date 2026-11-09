#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/volume" "$work/mnt" "$work/vol"

# A directory is a subvolume while the file DIR.is-subvolume lies beside it (so that the subvolume itself stays empty until a test
# fills it): stat then reports btrfs (STAT_FSTYPE) and inode 256, like the root of a real subvolume, and any other directory inode 257. STAT_ERROR makes stat fail like one refused by the kernel. The btrfs volume is the
# directory $TOP_VOL: mounting its top level (subvolid=5) copies it into the directory and marks that one .mounted, and unmounting
# copies it back and empties the directory, so that what is made in the top level survives. A mount point that lies under MOUNTS_UNDER
# and has an fstab line is mounted from the subvolume that line names, by copying it in and marking the mount point .mounted, and
# FAIL_MOUNT makes that mount fail. Any other mount of a path is only logged, so that no test mounts over the VM's real /tmp.
# FAIL_CP makes the copy into a subvolume fail, and the copy is made without its --reflink option, which not every filesystem a test runs
# on has; its arguments are logged as they came. FAIL_MV makes mv fail. A directory is NOCOW while LSATTR_NOCOW is set.
real_cp="$(command -v cp)"
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
  create) mkdir "$3" && touch "$3.is-subvolume" ;;
  delete) rm -rf "$3" "$3.is-subvolume" ;;
  *) exit 99 ;;
esac'
stub stat 'if [[ -n "${STAT_ERROR-}" ]]; then echo "stat: cannot statx ${*: -1}: Permission denied" >&2; exit 1; fi
case "$1" in
  -f) echo "${STAT_FSTYPE-btrfs}" ;;
  -c) if [[ -e "${*: -1}.is-subvolume" ]]; then echo 256; else echo 257; fi ;;
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
stub mount 'echo "mount $*" >> "$STUB_LOG"
if [[ "$1" == -o ]]; then
  '"$real_cp"' -a "$TOP_VOL/." "${*: -1}/"; touch "${*: -1}/.mounted"
elif [[ -n "${FAIL_MOUNT-}" ]]; then exit 1
elif [[ "$1" == "$MOUNTS_UNDER"/* ]]; then
  subvol="$(grep -F " $1 " "$VEKRONA_FSTAB" | grep -o "subvol=[^, ]*" | cut -d= -f2)"
  '"$real_cp"' -a "$TOP_VOL/$subvol/." "$1/"; touch "$1/.mounted"
fi'
stub umount 'echo "umount $*" >> "$STUB_LOG"; find "$TOP_VOL" -mindepth 1 -delete; '"$real_cp"' -a "$1/." "$TOP_VOL/"; rm -f "$TOP_VOL/.mounted"; find "$1" -mindepth 1 -delete'
stub cp 'echo "cp $*" >> "$STUB_LOG"
if [[ -n "${FAIL_CP-}" ]]; then exit 1; fi
args=(); for a in "$@"; do [[ "$a" == --reflink=* ]] || args+=("$a"); done
exec '"$real_cp"' "${args[@]}"'
real_mv="$(command -v mv)"
stub mv 'echo "mv $*" >> "$STUB_LOG"; if [[ -n "${FAIL_MV-}" ]]; then exit 1; fi; exec '"$real_mv"' "$@"'
stub lsattr 'if [[ -n "${LSATTR_NOCOW-}" ]]; then echo "---------------C------ ${*: -1}"; else echo "--------------------- ${*: -1}"; fi'
stub chattr 'echo "chattr $*" >> "$STUB_LOG"'
stub mountpoint '[[ -e "$2/.mounted" || ( "$2" == /tmp && -n "${TMP_MOUNTED-}" ) ]]'
# Every chmod is recorded; only the one of /tmp itself is not carried out.
real_chmod="$(command -v chmod)"
stub chmod 'echo "chmod $*" >> "$STUB_LOG"; if [[ "${*: -1}" != /tmp ]]; then exec '"$real_chmod"' "$@"; fi'
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" MOUNTS_UNDER="$work/mnt" TOP_VOL="$work/vol"
VEKRONA_FSTAB="$work/fstab"
export VEKRONA_FSTAB
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
[[ -e "$work/volume/tmp.is-subvolume" ]] || die "the subvolume was not created"
ensure_btrfs_subvolume tmp "$work/volume" 2>/dev/null
[[ "$(grep -c '^btrfs subvolume create' "$STUB_LOG")" -eq 1 ]] || die "an existing subvolume was created again"
log "ok: a subvolume is created once"

mkdir "$work/volume/plain"
if (ensure_btrfs_subvolume plain "$work/volume") 2>/dev/null; then die "a plain directory was taken for a subvolume"; fi
log "ok: a plain directory in the place of the subvolume is an error"

mkdir "$work/volume/ext"
touch "$work/volume/ext.is-subvolume"
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
ensure_top_subvolume_root tmp /tmp root:root 1777 "$work/top" 2>/dev/null
find "$work/top/tmp" -maxdepth 0 -perm 1777 | grep -q . || die "the new tmp subvolume is not mode 1777, so users cannot write /tmp after the next boot"
grep -qx "chown root:root $work/top/tmp" "$STUB_LOG" || die "the new tmp subvolume was not given to root"
grep -qx "chcon system_u:object_r:tmp_t:s0 $work/top/tmp" "$STUB_LOG" || die "the new tmp subvolume got no tmp_t label: $(<"$STUB_LOG")"
log "ok: a new tmp subvolume is root's, mode 1777 and labeled tmp_t before it is ever mounted"

chmod 0700 "$work/top/tmp"
ensure_top_subvolume_root tmp /tmp root:root 1777 "$work/top" 2>/dev/null
find "$work/top/tmp" -maxdepth 0 -perm 1777 | grep -q . || die "a tmp subvolume whose mode drifted was not made 1777 again"
log "ok: a tmp subvolume whose mode drifted is made 1777 again"

: > "$STUB_LOG"
SELINUX_OFF=1 ensure_top_subvolume_root tmp /tmp root:root 1777 "$work/top" 2>/dev/null
if grep -q '^chcon ' "$STUB_LOG"; then die "a label was set although SELinux is off"; fi
log "ok: with SELinux off the subvolume root gets no label"

# ensure_tmp_subvolume against a scratch fstab that holds /home's line. A running tmpfs /tmp is TMP_MOUNTED with FINDMNT_FSTYPE=tmpfs,
# a /tmp that is a plain directory is neither.
TMP_LINE='UUID=abc /tmp btrfs subvol=tmp,compress=zstd:1,nodev,nosuid 0 0'
fresh_fstab() { echo "$HOME_LINE" > "$VEKRONA_FSTAB"; : > "$STUB_LOG"; rm -rf "$TOP_VOL"; mkdir "$TOP_VOL"; }
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

# ensure_top_subvolume on mount points under $work/mnt, against a scratch fstab with /home's line.
IMAGES="$work/mnt/images"
IMAGES_LINE="UUID=abc $IMAGES btrfs subvol=libvirt-images,compress=zstd:1 0 0"
fresh_mountpoint() { rm -rf "$IMAGES" "$IMAGES.vekrona-old"; fresh_fstab; }
occupied_mountpoint() { fresh_mountpoint; mkdir -p "$IMAGES/sub"; echo disk > "$IMAGES/vm.qcow2"; echo more > "$IMAGES/sub/note"; }
logged() { grep -qE "$1" "$STUB_LOG"; }

fresh_mountpoint
run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -eq 0 ]] || die "an empty mount point was not made a subvolume mount: $stage_output"
logged "^btrfs subvolume create .*/libvirt-images$" || die "the subvolume was not created: $(<"$STUB_LOG")"
logged "^chmod 0711 .*/libvirt-images$" || die "the subvolume root got no mode 0711: $(<"$STUB_LOG")"
logged "^chcon system_u:object_r:tmp_t:s0 .*/libvirt-images$" || die "the subvolume root got no label: $(<"$STUB_LOG")"
fstab_is "$HOME_LINE"$'\n'"$IMAGES_LINE" || die "the fstab line of the subvolume is wrong: $(<"$VEKRONA_FSTAB")"
logged "^mount $IMAGES$" || die "the mount point was not mounted from fstab: $(<"$STUB_LOG")"
mountpoint -q "$IMAGES" || die "the mount point is not mounted after the mount"
if logged '^cp '; then die "nothing was there to copy, but cp ran"; fi
log "ok: an empty mount point gets its subvolume, an fstab line like /home's and the mount"

fresh_mountpoint
echo "$TMP_LINE" >> "$VEKRONA_FSTAB"
run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711 nodev
[[ "$stage_status" -eq 0 ]] || die "a second subvolume next to the tmp line failed: $stage_output"
fstab_is "$HOME_LINE"$'\n'"$TMP_LINE"$'\n'"${IMAGES_LINE/compress=zstd:1/compress=zstd:1,nodev}" || die "the second subvolume did not get its own line with the extra options: $(<"$VEKRONA_FSTAB")"
log "ok: a second subvolume is appended next to the first one's fstab line, with its extra options"

occupied_mountpoint
run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -eq 0 ]] || die "an occupied mount point was not migrated: $stage_output"
[[ "$(<"$IMAGES/vm.qcow2")" == disk && "$(<"$IMAGES/sub/note")" == more ]] || die "the files did not come back on the mounted subvolume"
mountpoint -q "$IMAGES" || die "the migrated mount point is not mounted"
[[ ! -e "$IMAGES.vekrona-old" ]] || die "the old directory was not deleted after the mount"
logged '^cp -a --reflink=auto .*/\. .*/libvirt-images/$' || die "the files were not copied as reflinks into the subvolume: $(<"$STUB_LOG")"
logged "^restorecon -R $IMAGES$" || die "the migrated files were not relabeled: $(<"$STUB_LOG")"
log "ok: the files of an occupied mount point are copied into the subvolume, mounted over, relabeled, and the old directory goes last"

# The old files are the only copy until the mount works, so a failing step must leave them where the system expects them or in .vekrona-old.
occupied_mountpoint
FAIL_MOUNT=1 run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -ne 0 ]] || die "a failing mount was reported as success"
[[ "$(<"$IMAGES.vekrona-old/vm.qcow2")" == disk ]] || die "the old files are gone after a failing mount"
[[ "$stage_output" == *"mv $IMAGES.vekrona-old $IMAGES"* ]] || die "the error does not say where the files are and how to restore them: $stage_output"
log "ok: a failing mount stops the stage with the old files kept in .vekrona-old"

occupied_mountpoint
FAIL_CP=1 run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -ne 0 ]] || die "a failing copy was reported as success"
[[ "$(<"$IMAGES/vm.qcow2")" == disk && ! -e "$IMAGES.vekrona-old" ]] || die "the mount point was touched after a failing copy"
if logged "^mount $IMAGES$"; then die "the mount point was mounted over after a failing copy"; fi
fstab_is "$HOME_LINE" || die "an fstab line was written after a failing copy: $(<"$VEKRONA_FSTAB")"
logged "^btrfs subvolume delete .*/libvirt-images$" || die "the subvolume with the partial copy was not deleted: $(<"$STUB_LOG")"
[[ ! -e "$TOP_VOL/libvirt-images" ]] || die "the subvolume with the partial copy is still in the top-level volume"
log "ok: a failing copy deletes the subvolume with its partial copy and stops the stage before the mount point is touched"

occupied_mountpoint
FAIL_MV=1 run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -ne 0 ]] || die "a failing rename was reported as success"
[[ "$(<"$IMAGES/vm.qcow2")" == disk && ! -e "$IMAGES.vekrona-old" ]] || die "the mount point was touched after a failing rename"
if logged "^mount $IMAGES$"; then die "the mount point was mounted over after a failing rename"; fi
log "ok: a failing rename of the old directory stops the stage with the mount point in place"

# A subvolume that is populated already and not mounted: a rollback to a root from before the migration brought the old files back.
occupied_mountpoint
mkdir "$TOP_VOL/libvirt-images"
touch "$TOP_VOL/libvirt-images.is-subvolume"
echo newer > "$TOP_VOL/libvirt-images/vm.qcow2"
run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -ne 0 && "$stage_output" == *"libvirt-images"* && "$stage_output" == *"$IMAGES"* ]] || die "a populated subvolume was accepted, or the error names no path: $stage_output"
[[ "$(<"$TOP_VOL/libvirt-images/vm.qcow2")" == newer && "$(<"$IMAGES/vm.qcow2")" == disk ]] || die "a populated subvolume or its mount point was changed"
if logged '^(cp|mv) |^mount [^-]'; then die "something was copied, moved or mounted although the subvolume holds files: $(<"$STUB_LOG")"; fi
log "ok: a subvolume that holds files but is not mounted is refused before anything is copied over it"

occupied_mountpoint
LSATTR_NOCOW=1 run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -eq 0 ]] || die "a NOCOW mount point was not migrated: $stage_output"
logged "^chattr \+C .*/libvirt-images$" || die "the subvolume of a NOCOW mount point was not made NOCOW: $(<"$STUB_LOG")"
log "ok: the subvolume of a NOCOW mount point is NOCOW before anything is copied into it"

occupied_mountpoint
run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -eq 0 ]] || die "a COW mount point was not migrated: $stage_output"
if logged '^chattr '; then die "the subvolume of a COW mount point was made NOCOW: $(<"$STUB_LOG")"; fi
log "ok: the subvolume of a COW mount point stays COW"

occupied_mountpoint
run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -eq 0 ]] || die "the first run failed: $stage_output"
: > "$STUB_LOG"
FINDMNT_ANSWER='/dev/vda3[/libvirt-images]' run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -eq 0 ]] || die "the second run failed: $stage_output"
if logged '^(cp|mv) |^mount [^-]'; then die "the second run copied, moved or mounted again: $(<"$STUB_LOG")"; fi
[[ "$(<"$IMAGES/vm.qcow2")" == disk && ! -e "$IMAGES.vekrona-old" ]] || die "the second run changed the migrated files"
log "ok: a second run after a migration copies, moves and mounts nothing"

occupied_mountpoint
echo "UUID=abc $IMAGES btrfs subvol=elsewhere,compress=zstd:1 0 0" >> "$VEKRONA_FSTAB"
run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -ne 0 && "$stage_output" == *"differs"* ]] || die "an fstab line for another subvolume was accepted: $stage_output"
[[ "$(<"$IMAGES/vm.qcow2")" == disk && ! -e "$IMAGES.vekrona-old" ]] || die "the mount point was touched although its fstab line differs"
log "ok: an fstab line of the mount point for another subvolume stops the stage before the mount point is touched"

occupied_mountpoint
mkdir "$IMAGES.vekrona-old"
run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -ne 0 && "$stage_output" == *".vekrona-old"* ]] || die "a leftover .vekrona-old was accepted: $stage_output"
[[ "$(<"$IMAGES/vm.qcow2")" == disk ]] || die "the mount point was touched next to a leftover .vekrona-old"
log "ok: a .vekrona-old left from an earlier migration is an error, not something to delete"

occupied_mountpoint
touch "$IMAGES/.mounted"
FINDMNT_ANSWER=/dev/sdb1 run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -ne 0 && "$stage_output" == *"/dev/sdb1"* ]] || die "a mount point mounted from another device was accepted: $stage_output"
if logged '^(cp|mount) '; then die "a mount point mounted from another device was copied or mounted over: $(<"$STUB_LOG")"; fi
log "ok: a mount point that is mounted from anything else is an error that leaves it alone"

fresh_mountpoint
mkdir -p "$IMAGES"
touch "$IMAGES/.mounted"
echo "$IMAGES_LINE" >> "$VEKRONA_FSTAB"
FINDMNT_ANSWER='/dev/vda3[/libvirt-images]' run_as_stage ensure_top_subvolume libvirt-images "$IMAGES" root:root 0711
[[ "$stage_status" -eq 0 ]] || die "a mount point already on its subvolume failed: $stage_output"
if logged '^(cp|mount|umount) .*images'; then die "a mount point already on its subvolume was copied or mounted again: $(<"$STUB_LOG")"; fi
fstab_is "$HOME_LINE"$'\n'"$IMAGES_LINE" || die "the fstab of a mount point already on its subvolume changed: $(<"$VEKRONA_FSTAB")"
log "ok: a mount point already on its subvolume is not copied or mounted again, and the second run changes nothing"
