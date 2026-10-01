#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 && -r "$1" ]] || { echo "usage: vm-run.sh RUN_ENV" >&2; exit 2; }
# shellcheck source=/dev/null
source "$1"

: "${STATE_DIR:?}" "${QMP_PY:?}" "${QEMU_CMD:?}"

trap 'echo "$?" > "$STATE_DIR/exited"' EXIT

if [[ -n "${HTTP_PORT:-}" ]]; then
  coproc HTTP_SERVER { exec python3 -u -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$SERVE_DIR"; }
  read -r _ <&"${HTTP_SERVER[0]}"
fi

"${QEMU_CMD[@]}" &

if [[ -n "${OWNER_PID:-}" ]]; then
  python3 -B "$QMP_PY" wait-pid "$OWNER_PID" &
fi

status=0
wait -n || status=$?
exit "$status"
