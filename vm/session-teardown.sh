#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=session-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/session-lib.sh"

session_teardown

echo "session-teardown OK"
