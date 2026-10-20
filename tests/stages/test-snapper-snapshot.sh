#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
SCRIPT="$ROOT/libexec/vekrona-snapper-snapshot"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export WORK="$work" PATH="$work/bin:$PATH"

# ps prints the command line the test sets; snapper records each argument on its own line and prints a snapshot number.
write_fake "$work/bin/ps" <<'F'
#!/usr/bin/env bash
cat "$WORK/cmdline"
F
write_fake "$work/bin/snapper" <<'F'
#!/usr/bin/env bash
printf '%s\n' "snapper" "$@" "--end--" >>"$WORK/snapper.args"
[[ ! -e "$WORK/snapper.fails" ]] || exit 1
echo 42
F
write_fake "$work/bin/logger" <<'F'
#!/usr/bin/env bash
echo "logger $*" >>"$WORK/logger"
F
reset() { : >"$work/snapper.args"; : >"$work/logger"; rm -f "$work/snapper.fails"; }

# A command line that would run a command if it ever met a shell.
HOSTILE="dnf install x'; touch $work/PWNED; echo '\$(touch $work/PWNED2)"
printf '%s\n' "$HOSTILE" >"$work/cmdline"

reset
out="$("$SCRIPT" pre 1234)"
[[ "$out" == "tmp.snapper_pre_number=42" ]] || die "pre must print the variable the post action reads: '$out'"
[[ ! -e "$work/PWNED" && ! -e "$work/PWNED2" ]] || die "the dnf command line was run by a shell"
grep -qxF -- "$HOSTILE" "$work/snapper.args" || die "the command line did not reach snapper as one argument, unchanged: $(cat "$work/snapper.args")"
grep -qx -- '-t' "$work/snapper.args" && grep -qx 'pre' "$work/snapper.args" || die "not a pre snapshot: $(cat "$work/snapper.args")"
log "ok: pre takes a pre snapshot described by the dnf command line, which stays one argument and never meets a shell"

reset
"$SCRIPT" post 1234 42 >"$work/out"
[[ ! -s "$work/out" ]] || die "post must print nothing: $(cat "$work/out")"
grep -qxF -- "$HOSTILE" "$work/snapper.args" || die "post: the command line did not reach snapper unchanged"
tr '\n' ' ' <"$work/snapper.args" | grep -q -- '--pre-number 42 ' || die "post is not paired with the pre snapshot: $(tr '\n' ' ' <"$work/snapper.args")"
[[ ! -e "$work/PWNED" && ! -e "$work/PWNED2" ]] || die "the dnf command line was run by a shell"
log "ok: post takes the matching post snapshot"

reset
: >"$work/snapper.args"
"$SCRIPT" post 1234 "" 2>"$work/err"
[[ ! -s "$work/snapper.args" ]] || die "a post snapshot was taken without a pre snapshot"
log "ok: without a pre snapshot there is no post snapshot"

reset
touch "$work/snapper.fails"
out="$("$SCRIPT" pre 1234 2>"$work/err")" || die "a failing snapper must not stop the dnf transaction"
[[ "$out" == "tmp.snapper_pre_number=" ]] || die "a failed pre snapshot must leave the variable empty: '$out'"
grep -q 'snapper could not take a snapshot' "$work/err" || die "the failure is not on stderr: $(cat "$work/err")"
grep -q 'logger .*snapper could not take a snapshot' "$work/logger" || die "the failure is not in the journal: $(cat "$work/logger")"
log "ok: a failing snapper is reported on stderr and in the journal, and the transaction goes on without a snapshot"

for args in "pre not-a-pid" "pre 12;ls" "post 1234 7;ls" "post 1234 lizard" "pre" "pre 1 2" "post 1234" "sideways 1234"; do
  reset
  # shellcheck disable=SC2086
  if "$SCRIPT" $args 2>"$work/err" >/dev/null; then die "accepted the arguments '$args'"; fi
  [[ ! -s "$work/snapper.args" ]] || die "snapper ran for the arguments '$args'"
done
log "ok: a pid or snapshot number that is not a number, and wrong argument counts, are refused before snapper runs"
