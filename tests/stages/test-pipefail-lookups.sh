#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export FAKE_GROUPS="$work/groups"

# Each stub prints the wanted answer first and a long tail after it, so a consumer that stops at the first match
# makes the producer die of SIGPIPE.
cat > "$work/bin/flatpak" <<'F'
#!/usr/bin/env bash
[[ -z "${FAKE_FLATPAK_FAIL:-}" ]] || { echo "flatpak: boom" >&2; exit 1; }
printf 'flathub\tsystem\n'
seq 1 300000
F
cat > "$work/bin/id" <<'F'
#!/usr/bin/env bash
[[ "$1" == -nG ]] || exec /usr/bin/id "$@"
[[ -z "${FAKE_ID_FAIL:-}" ]] || exit 1
printf '%s ' "${FAKE_ID_FIRST:-video}"
seq 1 300000 | tr '\n' ' '
echo
cat "$FAKE_GROUPS"
F
cat > "$work/bin/getent" <<'F'
#!/usr/bin/env bash
[[ "$1 $2" == "group video" ]] && echo "video:x:39:ann-marie" || exit 2
F
cat > "$work/bin/usermod" <<'F'
#!/usr/bin/env bash
[[ -n "${FAKE_USERMOD_NOOP:-}" ]] || echo " $2" >> "$FAKE_GROUPS"
F
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$work/bin/sudo"
chmod +x "$work"/bin/*
export PATH="$work/bin:$PATH"
: > "$FAKE_GROUPS"

outcome() { local out; if out="$("$@" 2>&1)"; then echo "ok"; else echo "failed: $out"; fi; }

[[ "$(outcome flatpak_remote_system_exists flathub)" == ok ]] || die "an existing remote listed first among 300000 lines was not found"
[[ "$(outcome flatpak_remote_system_enabled flathub)" == ok ]] || die "an enabled remote listed first among 300000 lines was not found"
[[ "$(outcome flatpak_remote_system_exists flat)" == failed* ]] || die "a remote name matched by prefix"
[[ "$(FAKE_FLATPAK_FAIL=1 outcome flatpak_remote_system_exists flathub)" == *"flatpak: boom"* ]] || die "a failing flatpak did not surface its own error"
[[ "$(FAKE_FLATPAK_FAIL=1 outcome flatpak_remote_system_enabled flathub)" == *"flatpak remotes failed"* ]] || die "a failing flatpak read as an absent remote"
log "ok: flatpak remote lookups survive a long listing and die when flatpak fails"

[[ "$(outcome user_in_group ann video)" == ok ]] || die "a group listed first among 300000 groups was not found"
[[ "$(outcome user_in_group ann vid)" == failed* ]] || die "a group name matched by prefix"
[[ "$(FAKE_ID_FAIL=1 outcome user_in_group ann video)" == *"id -nG ann failed"* ]] || die "a failing id read as 'not a member'"
log "ok: group membership survives a long group list and dies when id fails"

VEKRONA_USER=ann
export FAKE_ID_FIRST=ann
[[ "$(FAKE_USERMOD_NOOP=1 outcome ensure_user_in_group video)" == *"user not added to video"* ]] \
  || die "a member list holding ann-marie counted as holding ann"
[[ "$(outcome ensure_user_in_group video)" == ok ]] || die "a user whose group was added was reported as not added"
[[ "$(outcome ensure_user_in_group audio)" == *"group missing: audio"* ]] || die "a missing group was not reported"
log "ok: ensure_user_in_group verifies the exact member, not a word inside another name"
