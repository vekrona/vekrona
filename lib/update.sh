#!/usr/bin/env bash
# Root side of the update pipeline, shared by libexec/vekrona-update-{apply,check,night,post,skip}. docs/updates.md
# describes the whole flow. Source it after lib/common.sh.

# A failed root unit reaches the user through the unit-failed record that vekrona-error's watcher reads from the system
# journal. die's own report would land in root's state directory instead.
export VEKRONA_ERROR_REPORTER=/usr/bin/true

VEKRONA_STATE_DIR="${VEKRONA_STATE_DIR:-/var/lib/vekrona}"
VEKRONA_UPDATES_JSON="$VEKRONA_STATE_DIR/updates.json"
VEKRONA_UPDATE_SKIP_FILE="$VEKRONA_STATE_DIR/update-skip"
VEKRONA_OFFLINE_MARKER="$VEKRONA_STATE_DIR/offline-pending"
VEKRONA_UPDATE_LOCK="${VEKRONA_UPDATE_LOCK:-/run/vekrona-update.lock}"
VEKRONA_NIGHT_TIMER=vekrona-update-night.timer
# The steps the scripts start; tests replace them.
VEKRONA_PROTON="${VEKRONA_PROTON:-$VEKRONA_ROOT/bin/vekrona-proton}"
VEKRONA_UPDATE_CHECK="${VEKRONA_UPDATE_CHECK:-$VEKRONA_ROOT/libexec/vekrona-update-check}"
VEKRONA_UPDATE_APPLY="${VEKRONA_UPDATE_APPLY:-$VEKRONA_ROOT/libexec/vekrona-update-apply}"

require_root() { [[ $EUID -eq 0 ]] || die "$(basename "$0") must run as root"; }

# Holds the update lock until the process exits, so a check and an apply never run at the same time.
update_lock() {
  require_cmd flock
  exec {VEKRONA_UPDATE_LOCK_FD}>"$VEKRONA_UPDATE_LOCK"
  if ! flock --nonblock "$VEKRONA_UPDATE_LOCK_FD"; then
    log "another update step holds $VEKRONA_UPDATE_LOCK, waiting for it"
    flock "$VEKRONA_UPDATE_LOCK_FD"
  fi
}

# Every dnf transaction ends here: the 1Password RPM's %post rewrites its repo file and disables repo_gpgcheck.
update_postflight() { ensure_1password_repo_file; }

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

# Reads the groups array on stdin, brings the night timer in line with it and writes updates.json.
update_publish() {
  local checked="$1" groups pending armed=false
  groups="$(cat)"
  pending="$(jq 'length > 0' <<<"$groups")"
  update_sync_night_timer "$pending"
  if update_night_armed; then armed=true; fi
  jq --arg checked "$checked" --argjson armed "$armed" \
    '{checked: $checked, pending: (length > 0), night_armed: $armed, groups: .}' <<<"$groups" | update_write_json
  log "wrote $VEKRONA_UPDATES_JSON: pending=$pending night_armed=$armed"
}

# jq program for the groups array. Inputs: $installed (rpm -qa lines "name.arch<TAB>evr", oldest first), $dnf (the
# check-upgrade document; a package offered for two architectures counts once), $flatpak (lines "application<TAB>version")
# and $mise (mise outdated --json). Empty groups go. claude-code comes from dnf but belongs with the other agents, and
# the Proton RPMs come from the local vekrona-proton repo.
UPDATE_GROUPS_JQ='
  def evr: sub("^0:"; "");
  def lines: split("\n") | map(select(length > 0) | split("\t"));
  def plain: map({name, from, to});
  ($installed | lines | map({key: .[0], value: .[1]}) | from_entries) as $inst
  | (($dnf[0].upgrades // [])
      | map({name, repository, to: (.evr | evr), from: (($inst["\(.name).\(.arch)"] // "") | evr)})
      | group_by(.name) | map(sort_by(.from == "") | first)) as $rpms
  | [
      {name: "System packages", items: ($rpms | map(select(.name != "claude-code" and .repository != "vekrona-proton")) | plain)},
      {name: "Agents", items: (
        ($rpms | map(select(.name == "claude-code")) | plain)
        + (($mise[0] // {}) | to_entries | sort_by(.key)
           | map({name: (.key | sub("^[a-z]+:"; "") | split("/") | last | sub("-coding-agent$"; "")),
                  from: (.value.current // ""), to: (.value.latest // "")})))},
      {name: "Flatpak", items: ($flatpak | lines | map({name: .[0], from: "", to: (.[1] // "")}))},
      {name: "Proton", items: ($rpms | map(select(.repository == "vekrona-proton")) | plain)}
    ] | map(select(.items | length > 0))'

# Queries every source into DIR and prints the groups array.
update_collect_groups() {
  local dir="$1" status=0
  "$VEKRONA_PROTON" stage
  # With --json, dnf5 exits 0 whether or not updates exist (the exit status 100 belongs to the plain output), and
  # prints {} when there are none.
  dnf5 check-upgrade --refresh --json </dev/null >"$dir/dnf.json" || status=$?
  [[ "$status" -eq 0 ]] || die "dnf5 check-upgrade failed with exit status $status"
  rpm -qa --qf '%{NAME}.%{ARCH}\t%|EPOCH?{%{EPOCH}:}|%{VERSION}-%{RELEASE}\n' | sort -V >"$dir/installed.tsv"
  flatpak remote-ls --updates --system --columns=application,version >"$dir/flatpak.tsv"
  mise_system outdated --json >"$dir/mise.json"
  jq -n -c --rawfile installed "$dir/installed.tsv" --rawfile flatpak "$dir/flatpak.tsv" \
    --slurpfile dnf "$dir/dnf.json" --slurpfile mise "$dir/mise.json" "$UPDATE_GROUPS_JQ"
}

update_check_in() {
  local dir="$1"
  update_collect_groups "$dir" >"$dir/groups.json"
  update_publish "$(date -Iseconds)" <"$dir/groups.json"
}

# Looks for updates everywhere and rewrites updates.json. The caller holds the update lock.
update_check() {
  require_cmd jq flatpak mise
  with_scratch_dir update_check_in
}

# One line per group: "Agents 2, Flatpak 1".
update_summary() { jq -r '.groups | map("\(.name) \(.items | length)") | join(", ")' "$VEKRONA_UPDATES_JSON"; }

# Prints the block inhibitors on shutdown, one line each (who, why and the rest of systemd-inhibit's table row).
shutdown_blockers() {
  local table
  table="$(systemd-inhibit --list --no-legend --no-pager)"
  awk '$NF == "block" { for (i = 2; i < NF; i++) if ($i ~ /^([a-z-]+:)*shutdown(:[a-z-]+)*$/) { print; next } }' <<<"$table"
}
