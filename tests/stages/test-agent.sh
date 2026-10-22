#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-agent"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/config" SCRATCH="$scratch"
mkdir -p "$HOME"

stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$stubs/$1"; chmod +x "$stubs/$1"; }
stub claude 'exit 0'
stub ghostty 'exit 0'
stub qs 'exit 0'
stub systemctl 'echo "PATH=/usr/bin"'
stub systemd-run 'echo "Failed to start transient service: Access denied" >&2; exit 1'
stub reporter 'echo "$*" >> "$SCRATCH/reported"'
export VEKRONA_ERROR_REPORTER="$stubs/reporter"

agent() {
  rc=0
  out="$(PATH="$stubs:$PATH" "$tool" "$@" 2>"$scratch/stderr")" || rc=$?
}

agent get
[[ "$rc" == 0 && -z "$out" ]] || die "get with no default must print nothing and succeed: exit $rc, '$out', $(cat "$scratch/stderr")"
agent set claude
[[ "$rc" == 0 ]] || die "set claude failed: $(cat "$scratch/stderr")"
agent get
[[ "$rc" == 0 && "$out" == claude ]] || die "get must print the default: exit $rc, '$out'"
log "ok: get prints the default, or nothing when none is set"

agent --prompt hello
[[ "$rc" == 1 ]] || die "a launch whose systemd-run failed must fail, got exit $rc"
grep -q 'Access denied' "$scratch/stderr" || die "the reason systemd-run gave is lost: $(cat "$scratch/stderr")"
grep -q 'Access denied' "$scratch/reported" || die "the reported failure lacks the reason: $(cat "$scratch/reported" 2>&1)"
log "ok: a failing systemd-run is reported with its own message"
