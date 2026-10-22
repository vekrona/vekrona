#!/usr/bin/env bash
# Root side of the update pipeline, shared by libexec/vekrona-update-{apply,check,night,post,skip} and
# libexec/vekrona-kernel-ready. docs/updates.md
# describes the whole flow. Source it after lib/common.sh.

VEKRONA_STATE_DIR="${VEKRONA_STATE_DIR:-/var/lib/vekrona}"
VEKRONA_UPDATES_JSON="$VEKRONA_STATE_DIR/updates.json"
VEKRONA_UPDATE_SKIP_FILE="$VEKRONA_STATE_DIR/update-skip"
# shellcheck disable=SC2034 # read by vekrona-update-apply and vekrona-update-post, which source this file
VEKRONA_OFFLINE_MARKER="$VEKRONA_STATE_DIR/offline-pending"
# Second line of the marker: the snapshot number vekrona-update-apply took before storing the offline transaction.
OFFLINE_MARKER_PRE_KEY=pre=
VEKRONA_NIGHT_TIMER=vekrona-update-night.timer
# The steps the scripts start; tests replace them.
VEKRONA_PROTON="${VEKRONA_PROTON:-$VEKRONA_ROOT/bin/vekrona-proton}"
VEKRONA_UPDATE_CHECK="${VEKRONA_UPDATE_CHECK:-$VEKRONA_ROOT/libexec/vekrona-update-check}"
VEKRONA_UPDATE_APPLY="${VEKRONA_UPDATE_APPLY:-$VEKRONA_ROOT/libexec/vekrona-update-apply}"

# Stages the Proton RPMs. A feed that cannot be read or verified must not hold back the Fedora and Flatpak updates, so its
# failure is reported on its own, as one record that names the cause, and the run goes on with what is already staged.
# The stage's own report is switched off for it: the record made here carries its message.
update_stage_proton() {
  local output status=0
  output="$(VEKRONA_ERROR_REPORTER=/usr/bin/true "$VEKRONA_PROTON" stage 2>&1)" || status=$?
  [[ -z "$output" ]] || printf '%s\n' "$output" >&2
  [[ "$status" -eq 0 ]] || report_failure "Proton packages were not updated, the other updates go on (vekrona-proton stage exited with status $status): $(tail -n 3 <<<"$output" | sed 's/\x1b\[[0-9;]*m//g')"
}

# Every dnf transaction ends here: the 1Password RPM's %post rewrites its repo file and disables repo_gpgcheck.
update_postflight() { ensure_1password_repo_file; }

# UPDATEDEFAULT=no keeps kernel-install from making the new kernel the GRUB default, so every update ends by doing it.
# On an NVIDIA machine kernel-install built the initramfs before akmods@<kver> built nvidia and an offline update skips
# that build altogether, so this builds what is missing first. Dies then, naming the way out, when that fails.
update_promote_newest_kernel() {
  local kver
  kver="$(newest_installed_kver)"
  if pkg_installed akmod-nvidia; then
    wait_for_akmods_idle
    ensure_kernel_boots_with_nvidia "$kver"
  else
    set_default_kernel "$kver"
  fi
}

update_skipped_today() { [[ -f "$VEKRONA_UPDATE_SKIP_FILE" && "$(<"$VEKRONA_UPDATE_SKIP_FILE")" == "$(date +%F)" ]]; }

update_night_armed() { [[ "$(systemctl is-active "$VEKRONA_NIGHT_TIMER" 2>/dev/null || true)" == active ]]; }

# The night timer runs when something is pending and tonight was not skipped.
update_sync_night_timer() {
  local pending="$1"
  if [[ "$pending" == true ]] && ! update_skipped_today; then
    log "arming $VEKRONA_NIGHT_TIMER"
    systemctl start "$VEKRONA_NIGHT_TIMER"
  else
    log "disarming $VEKRONA_NIGHT_TIMER"
    systemctl stop "$VEKRONA_NIGHT_TIMER"
  fi
}

# Replaces updates.json with stdin in one rename, so a reader never sees half a file.
update_write_json() {
  local tmp
  install -d -m 0755 "$VEKRONA_STATE_DIR"
  tmp="$(mktemp "$VEKRONA_STATE_DIR/.updates.json.XXXXXX")"
  { cat >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$VEKRONA_UPDATES_JSON"; } || { rm -f "$tmp"; die "cannot write $VEKRONA_UPDATES_JSON"; }
}

# jq program turning the groups array into the document updates.json holds. Arguments: $checked, $armed.
# shellcheck disable=SC2016 # jq variables are meant to stay unexpanded
UPDATE_STATE_JQ='{checked: $checked, pending: (length > 0), night_armed: $armed, groups: .}'

# Writes the state of "nothing checked yet" unless updates.json exists, so the shell can always watch the file and its
# directory (a watch on a missing directory never fires).
update_seed_json() {
  [[ -e "$VEKRONA_UPDATES_JSON" ]] && return 0
  jq -n -c --arg checked "" --argjson armed false "[] | $UPDATE_STATE_JQ" | update_write_json
  log "seeded $VEKRONA_UPDATES_JSON"
}

# Reads the groups array on stdin, brings the night timer in line with it and writes updates.json.
update_publish() {
  local checked="$1" groups pending armed=false
  groups="$(cat)"
  pending="$(jq 'length > 0' <<<"$groups")"
  update_sync_night_timer "$pending"
  if update_night_armed; then armed=true; fi
  jq --arg checked "$checked" --argjson armed "$armed" "$UPDATE_STATE_JQ" <<<"$groups" | update_write_json
  log "wrote $VEKRONA_UPDATES_JSON: pending=$pending night_armed=$armed"
}

# jq program for the groups array. Inputs: $installed (rpm -qa lines "name.arch<TAB>evr", oldest first), $dnf (the
# check-upgrade document; a package offered for two architectures counts once), $skipped (lines "name.arch" of the
# updates that `dnf5 upgrade` leaves out) and $flatpak (lines "application<TAB>version"). Empty groups go. The Proton
# RPMs come from the local vekrona-proton repo and get their own group.
# shellcheck disable=SC2016 # jq variables ($installed, $dnf, ...) are meant to stay unexpanded
UPDATE_GROUPS_JQ='
  def evr: sub("^0:"; "");
  def lines: split("\n") | map(select(length > 0) | split("\t"));
  def plain: map({name, from, to});
  ($installed | lines | map({key: .[0], value: .[1]}) | from_entries) as $inst
  | ($skipped | split("\n") | map(select(length > 0))) as $skip
  | (($dnf[0].upgrades // [])
      | map(select("\(.name).\(.arch)" | IN($skip[]) | not))
      | map({name, repository, to: (.evr | evr), from: (($inst["\(.name).\(.arch)"] // "") | evr)})
      | group_by(.name) | map(sort_by(.from == "") | first)) as $rpms
  | [
      {name: "System packages", items: ($rpms | map(select(.repository != "vekrona-proton")) | plain)},
      {name: "Flatpak", items: ($flatpak | lines | map({name: .[0], from: "", to: (.[1] // "")}))},
      {name: "Proton", items: ($rpms | map(select(.repository == "vekrona-proton")) | plain)}
    ] | map(select(.items | length > 0))'

# Prints "name.arch" of every update that `dnf5 upgrade` leaves out, one per line, read from its answer to a transaction
# it does not run (--assumeno). check-upgrade lists them all: a repository that lags behind another (RPM Fusion's
# mesa-va-drivers-freeworld behind Fedora's mesa) leaves packages with conflicts or broken dependencies, which dnf
# skips, so the update would be offered and then install nothing. dnf exits 1 after it declined a transaction.
dnf_skipped_updates() {
  local out="$1" status=0
  dnf5 upgrade --assumeno </dev/null >"$out" 2>&1 || status=$?
  if [[ "$status" -ne 0 ]] && { [[ "$status" -ne 1 ]] || ! grep -q 'Operation aborted by the user\.' "$out"; }; then
    die "dnf5 upgrade --assumeno failed with exit status $status: $(tail -n 5 "$out")"
  fi
  awk '/^Skipping packages with .*:$/ { skipping = 1; next } /^[^ ]/ { skipping = 0 } skipping && NF { print $1 "." $2 }' "$out"
}

# Queries every source into DIR and prints the groups array.
update_collect_groups() {
  local dir="$1" status=0
  update_stage_proton
  # With --json, dnf5 exits 0 whether or not updates exist (the exit status 100 belongs to the plain output), and
  # prints {} when there are none.
  dnf5 check-upgrade --refresh --json </dev/null >"$dir/dnf.json" || status=$?
  [[ "$status" -eq 0 ]] || die "dnf5 check-upgrade failed with exit status $status"
  dnf_skipped_updates "$dir/upgrade.txt" >"$dir/skipped.txt"
  if [[ -s "$dir/skipped.txt" ]]; then log "dnf5 upgrade leaves out these listed updates: $(paste -sd' ' "$dir/skipped.txt")"; fi
  rpm -qa --qf '%{NAME}.%{ARCH}\t%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}\n' | sort -V >"$dir/installed.tsv"
  flatpak remote-ls --updates --system --columns=application,version >"$dir/flatpak.tsv"
  jq -n -c --rawfile installed "$dir/installed.tsv" --rawfile skipped "$dir/skipped.txt" --rawfile flatpak "$dir/flatpak.tsv" \
    --slurpfile dnf "$dir/dnf.json" "$UPDATE_GROUPS_JQ"
}

update_check_in() {
  local dir="$1"
  update_collect_groups "$dir" >"$dir/groups.json"
  update_publish "$(date -Iseconds)" <"$dir/groups.json"
}

# Looks for updates everywhere and rewrites updates.json. The caller holds the update lock.
update_check() {
  require_cmd jq flatpak
  with_scratch_dir update_check_in
}

# One line per group: "System packages 2, Flatpak 1".
update_summary() { jq -r '.groups | map("\(.name) \(.items | length)") | join(", ")' "$VEKRONA_UPDATES_JSON"; }

# Prints the block inhibitors on shutdown, one line each (who, why and the rest of systemd-inhibit's table row).
shutdown_blockers() {
  local table
  table="$(systemd-inhibit --list --no-legend --no-pager)"
  awk '$NF == "block" { for (i = 2; i < NF; i++) if ($i ~ /^([a-z-]+:)*shutdown(:[a-z-]+)*$/) { print; next } }' <<<"$table"
}

# Takes the post snapshot of the pair the offline-pending marker names; the transaction it brackets has run by now. A
# snapshot that cannot be taken is recorded and the update goes on: the kernel must not wait for a rollback point.
update_close_offline_snapshot_pair() {
  local pre_number post_number
  pre_number="$(sed -n "s/^$OFFLINE_MARKER_PRE_KEY//p" "$VEKRONA_OFFLINE_MARKER")"
  if [[ ! "$pre_number" =~ ^[0-9]+$ ]]; then
    report_failure "$VEKRONA_OFFLINE_MARKER names no pre-update snapshot (found '$pre_number'): the offline update has no post snapshot"
    return 0
  fi
  if post_number="$(snapper -c root create -p -c number -d "vekrona-update post" --pre-number "$pre_number")" && [[ -n "$post_number" ]]; then
    log "post-update snapshot: $post_number (roll back with: vekrona-rollback $pre_number)"
  else
    report_failure "failed to create the post-update snapshot; pre-update snapshot $pre_number has no matching post snapshot"
  fi
}
