#!/usr/bin/env bash
# Regression for the live foreign session-lock owner and non-owner Stop loop.
# The executable reproduction runs the real auto-arm and turn-end guard paths.
set -eu

# The shared library gives the reproduction the guarded signal helper and the
# test identity it checks (signal policy P-010).
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

python3 "$(dirname "${BASH_SOURCE[0]}")/fm-turnend-foreign-owner-repro.py"
