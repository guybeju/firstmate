#!/usr/bin/env bash
# fm-topic-board-read.sh - read-only summary of one home for the topic board.
#
# Usage:
#   fm-topic-board-read.sh <ledger-offset> <prefix-sha256>
#   fm-topic-board-read.sh --in-home <secondmate-id> <ledger-offset> <prefix-sha256>
#
# Prints one JSON object describing this home: its tasks and their current
# state, its captain holds, worker needs-decision questions, every topic tag
# file, and the fleet-ledger lines written since <ledger-offset>. The first call
# passes "0 -"; each later call passes the previous output's ledger.to_offset
# and ledger.to_prefix_sha256. The main home's output also lists the registered
# secondmates. --in-home reads a LOCAL registered secondmate home instead.
#
# Task state, holds, and worker questions come from fm-fleet-snapshot.sh --json;
# this script does not parse status logs or state files itself. The one
# exception is a hold's origin, taken from its "Captain hold origin:" body line.
#
# ledger.status is "delta" (lines follow), "absent" (no ledger file), or
# "continuity-broken" (the ledger is shorter than <ledger-offset> or its first
# <ledger-offset> bytes no longer hash to <prefix-sha256>; re-read from "0 -").
# Only complete lines are returned, at most 256 KiB per call; ledger.more is
# true when that cap cut the read short.
#
# "schema" is this output format's version. This script writes nothing in the
# home. Exit codes: 0 success, 1 failure (nothing is printed), 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SCHEMA=1
LEDGER_MAX_BYTES=262144

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-topic-lib.sh
. "$SCRIPT_DIR/fm-topic-lib.sh"

usage_error() {
  printf '%s\n' "fm-topic-board-read.sh: $*" >&2
  printf '%s\n' "usage: fm-topic-board-read.sh [--in-home <secondmate-id>] <ledger-offset> <prefix-sha256>" >&2
  exit 2
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

# Write the ledger section of the output to <out-file>.
ledger_section() {
  local offset=$1 prefix=$2 out=$3 ledger="$STATE/fleet-ledger.jsonl"
  local size remaining newlines consumed more=false to_offset to_prefix=-
  if [ ! -f "$ledger" ]; then
    jq -n '{status: "absent", to_offset: 0, to_prefix_sha256: "-", more: false, lines: []}' > "$out"
    return 0
  fi
  size=$(file_size "$ledger")
  if [ "$offset" -gt "$size" ] ||
    { [ "$offset" -gt 0 ] && [ "$(head -c "$offset" "$ledger" | sha256_stdin)" != "$prefix" ]; }; then
    jq -n '{status: "continuity-broken", to_offset: 0, to_prefix_sha256: "-", more: false, lines: []}' > "$out"
    return 0
  fi
  remaining=$((size - offset))
  tail -c "+$((offset + 1))" "$ledger" | head -c "$LEDGER_MAX_BYTES" > "$WORK/chunk"
  newlines=$(wc -l < "$WORK/chunk" | tr -d ' ')
  if [ "$newlines" -gt 0 ]; then
    head -n "$newlines" "$WORK/chunk" > "$WORK/lines"
  elif [ "$remaining" -gt "$LEDGER_MAX_BYTES" ]; then
    # One line longer than the cap: return that single line whole when it is
    # already terminated, so the reader can never get stuck in front of it.
    tail -c "+$((offset + 1))" "$ledger" | head -n 1 > "$WORK/lines"
    [ "$(tail -c 1 "$WORK/lines" | wc -l | tr -d ' ')" -eq 1 ] || : > "$WORK/lines"
  else
    : > "$WORK/lines"
  fi
  consumed=$(file_size "$WORK/lines")
  to_offset=$((offset + consumed))
  if [ "$to_offset" -gt 0 ]; then
    to_prefix=$(head -c "$to_offset" "$ledger" | sha256_stdin)
  fi
  if [ "$consumed" -gt 0 ] && [ "$remaining" -gt "$LEDGER_MAX_BYTES" ]; then
    more=true
  fi
  jq -R -n --argjson to_offset "$to_offset" --arg to_prefix "$to_prefix" --argjson more "$more" \
    '{status: "delta", to_offset: $to_offset, to_prefix_sha256: $to_prefix, more: $more, lines: [inputs]}' \
    < "$WORK/lines" > "$out"
}

# Write {"<task-id>": "<tag file content>"} for every tagged task to <out-file>.
topics_section() {
  local out=$1 file task
  for file in "$DATA"/*/topic; do
    [ -f "$file" ] || continue
    task=${file%/topic}
    task=${task##*/}
    # A tab can never start a tag line, so it marks where the next task begins.
    printf '\t%s\n%s\n' "$task" "$(< "$file")"
  done | jq -R -n '
    reduce inputs as $line ({tags: {}, task: null};
      if ($line | startswith("\t")) then .task = $line[1:] | .tags[.task] = []
      elif .task != null then .tags[.task] += [$line]
      else . end)
    | .tags | map_values(join("\n"))
  ' > "$out"
}

# Write the registered secondmates as a JSON array to <out-file>.
secondmates_section() {
  local out=$1 reg="$DATA/secondmates.md" line
  if [ -f "$reg" ] && [ ! -L "$reg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '- '*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" || continue
      jq -n --arg id "$SECONDMATE_REGISTRY_ID" --arg home "$SECONDMATE_REGISTRY_HOME" \
        --argjson remote "$SECONDMATE_REGISTRY_REMOTE" '{id: $id, remote: ($remote == 1), home: $home}'
    done < "$reg"
  fi | jq -s '.' > "$out"
}

# The commit of the code this home runs. A home is normally its own checkout,
# and a local secondmate home can lag behind the main home whose script is
# reading it, so the home's own HEAD is preferred over the code root's.
home_commit() {
  local top
  top=$(git -C "$FM_HOME" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$FM_HOME" && pwd -P)" ]; then
    git -C "$FM_HOME" rev-parse HEAD 2>/dev/null && return 0
  fi
  git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || true
}

main() {
  local offset prefix home is_secondmate=false ledger_enabled=false code_commit
  if [ "${1:-}" = --in-home ]; then
    [ "$#" -eq 4 ] || usage_error "--in-home needs a secondmate id, an offset, and a prefix hash"
    home=$(tb_local_secondmate_home "$DATA/secondmates.md" "$2") || exit 1
    tb_exec_in_home "$home" "$SCRIPT_DIR/fm-topic-board-read.sh" "$3" "$4"
  fi
  [ "$#" -eq 2 ] || usage_error "expected an offset and a prefix hash"
  offset=$1
  prefix=$2
  case "$offset" in '' | *[!0-9]*) usage_error "the offset must be a non-negative integer: $offset" ;; esac
  if [ "$prefix" != - ]; then
    case "$prefix" in *[!0-9a-f]*) usage_error "the prefix hash must be 64 hex characters or '-'" ;; esac
    [ "${#prefix}" -eq 64 ] || usage_error "the prefix hash must be 64 hex characters or '-'"
  fi
  command -v jq >/dev/null 2>&1 ||
    tb_die 1 "fm-topic-board-read.sh needs jq, which was not found. Install: $(tb_jq_install_hint)"

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-topic-board-read.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT

  FM_HOME="$FM_HOME" FM_SNAPSHOT_SECONDMATES=1 FM_SNAPSHOT_BUDGET=1 FM_CREW_STATE_NO_FORGE=1 \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$WORK/snapshot" ||
    tb_die 1 "fm-topic-board-read.sh: fm-fleet-snapshot.sh failed"

  ledger_section "$offset" "$prefix" "$WORK/ledger"
  topics_section "$WORK/topics"
  if fm_root_is_secondmate_home "$FM_HOME"; then
    is_secondmate=true
    printf '[]\n' > "$WORK/secondmates"
  else
    secondmates_section "$WORK/secondmates"
  fi
  if [ -e "$CONFIG/fleet-ledger" ]; then
    ledger_enabled=true
  fi
  code_commit=$(home_commit)

  jq -n --argjson schema "$SCHEMA" --arg code_commit "$code_commit" \
    --argjson ledger_enabled "$ledger_enabled" --argjson is_secondmate "$is_secondmate" \
    --slurpfile snapshot "$WORK/snapshot" --slurpfile ledger "$WORK/ledger" \
    --slurpfile topics "$WORK/topics" --slurpfile secondmates "$WORK/secondmates" '
    $snapshot[0] as $snap
    | {
        schema: $schema,
        code_commit: $code_commit,
        generated: $snap.generated,
        ledger_enabled: $ledger_enabled,
        tasks: [ $snap.tasks[]
                 | {id, kind, state: (.current_state.state // "unknown"),
                    source: (.current_state.source // ""), detail: (.current_state.detail // ""),
                    unstarted: (.current_state.state == "working"
                                and .current_state.detail == "harness busy (fm-spawn)")} ],
        holds: [ $snap.backlog.records[]
                 | select(.structured == true and .hold_kind == "captain"
                          and .hold_reason != null and .state != "done")
                 | {id, title, question: .hold_reason, hold_bucket, hold_until,
                    unresolved_blocker_ids: (.unresolved_blocker_ids // []),
                    hold_age_days,
                    origin: ([ (.body_lines // [])[]
                               | capture("^Captain hold origin: (?<origin>.*)$") | .origin ][0] // "")} ],
        status_decisions: [ $snap.tasks[] | .id as $id
                            | (.hints.open_decisions // [])[]
                            | select(.verb == "needs-decision")
                            | {id: $id, key, summary} ],
        topics: $topics[0],
        ledger: $ledger[0]
      }
    | if $is_secondmate then . else . + {secondmates: $secondmates[0]} end
  ' > "$WORK/output" || tb_die 1 "fm-topic-board-read.sh: could not assemble the output"
  cat "$WORK/output"
}

main "$@"
