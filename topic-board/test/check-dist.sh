#!/usr/bin/env bash
# Fails when topic-board/dist is not exactly what tsc produces from
# topic-board/src. The runtime only ever runs dist/, so a stale build would ship
# old behavior. Skips when the dev dependency is not installed.
#
# Usage: topic-board/test/check-dist.sh
set -euo pipefail

BOARD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSC="$BOARD/node_modules/.bin/tsc"
if [ ! -x "$TSC" ]; then
  echo "skip: typescript is not installed (run pnpm install in topic-board/)"
  exit 0
fi

fresh=$(mktemp -d "${TMPDIR:-/tmp}/topic-board-dist.XXXXXX")
trap 'rm -rf "$fresh"' EXIT
"$TSC" -p "$BOARD" --outDir "$fresh"
if ! diff -r "$fresh" "$BOARD/dist"; then
  echo "check-dist.sh: topic-board/dist is stale; run 'pnpm run build' in topic-board/ and commit the result" >&2
  exit 1
fi
echo "ok - topic-board/dist matches topic-board/src"
