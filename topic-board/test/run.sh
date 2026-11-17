#!/usr/bin/env bash
# Runs the topic-board test scripts for the given stages (all stages when none
# are named). Each script is topic-board/test/stage-<n>-*.sh and exits non-zero
# on its first failed assertion. The scripts run under the bash that runs this
# file, so `/bin/bash run.sh` checks them against that bash.
#
# Usage: topic-board/test/run.sh [stage-number...]
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- 1 2 3 4 5 6
fi

ran=0
for stage in "$@"; do
  case "$stage" in
    [1-6]) ;;
    *)
      echo "run.sh: unknown stage '$stage' (expected 1-6)" >&2
      exit 2
      ;;
  esac
  for script in "$TEST_DIR"/stage-"$stage"-*.sh; do
    [ -f "$script" ] || continue
    echo "# $(basename "$script")"
    "${BASH:-bash}" "$script"
    ran=$((ran + 1))
  done
done
[ "$ran" -gt 0 ] || {
  echo "run.sh: no test scripts found for stages: $*" >&2
  exit 1
}
echo "# topic-board tests passed ($ran scripts)"
