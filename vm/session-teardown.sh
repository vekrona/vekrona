#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/session-lib.sh"

session_teardown

echo "session-teardown OK"
