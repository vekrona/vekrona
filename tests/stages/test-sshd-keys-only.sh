#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/tailnet-ssh.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export WORK="$work"
write_fake "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
# sshd refuses any configuration while the host has no keys, as one that never started does not.
write_fake "$work/bin/sshd" <<'F'
#!/usr/bin/env bash
[[ -e "$WORK/host-keys" ]] || { echo "sshd: no hostkeys available -- exiting." >&2; exit 1; }
F
write_fake "$work/bin/ssh-keygen" <<'F'
#!/usr/bin/env bash
[[ "$1" == -A ]] && touch "$WORK/host-keys"
F
write_fake "$work/bin/systemctl" <<'F'
#!/usr/bin/env bash
echo inactive
exit 3
F
PATH="$work/bin:$PATH"
has_sshd() { true; }
SSHD_DROPIN="$work/10-vekrona.conf"

rc=0
(ensure_sshd_keys_only) >"$work/out" 2>&1 || rc=$?
[[ "$rc" == 0 ]] || die "a host that never started sshd must get its host keys before the configuration is checked: $(cat "$work/out")"
cmp -s "$ROOT/etc/ssh/sshd_config.d/10-vekrona.conf" "$SSHD_DROPIN" || die "the drop-in was not installed"
log "ok: host keys are generated before sshd checks the drop-in"
