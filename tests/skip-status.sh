# shellcheck shell=bash
# The exit status of a test that did not run because the machine cannot (root has no desktop to toast on, the container allows no
# user namespaces). It is the one Automake's test harness uses. The runners (tests/run.sh, tests/stages/run.sh) count and report it,
# so that a skipped test never reads as a passed one. Sourced by tests/lib.sh and by the runners.
SKIP_EXIT_STATUS=77
