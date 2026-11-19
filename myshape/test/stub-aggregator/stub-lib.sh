#!/usr/bin/env bash
# What both stub aggregators share: the call log, the controls that make a
# feed misbehave, and the deliverer that records each action record and
# answers from a play file. Sourced by stub-fm and stub-plain; everything lives
# under $TB_AGG.
#
#   $TB_AGG/calls.log        "feed <home> <offset> <sha> <time>" or "deliver <id> <kind> <time>"
#   $TB_AGG/received.jsonl   every action record, as received
#   $TB_AGG/play             the next outcomes, one per line: an outcome line
#                            ({"outcome":…}), or "sleep <seconds> <outcome line>";
#                            an empty file answers {"outcome":"delivered"}
#   $TB_AGG/control/<home>   how the feed for <home> misbehaves until removed:
#                            "sleep <seconds>", "exit4 <line>", "fail <line>",
#                            "garbage", "schema2"
#   $TB_AGG/env.<home>       written on every feed call when $TB_AGG/env-probe exists:
#                            the names of the environment the program got

set -euo pipefail

stub_now() {
  date +%s.%N 2>/dev/null || date +%s
}

stub_log() {
  printf '%s %s\n' "$*" "$(stub_now)" >> "$TB_AGG/calls.log"
}

# stub_control <home>: misbehaves as $TB_AGG/control/<home> says; returns when the
# feed should answer normally.
stub_control() {
  local file="$TB_AGG/control/$1" mode rest
  [ -f "$file" ] || return 0
  read -r mode rest < "$file" || true
  case "$mode" in
    sleep) sleep "$rest" ;;
    exit4) printf '%s\n' "$rest" >&2; exit 4 ;;
    fail) printf '%s\n' "$rest" >&2; exit 1 ;;
    garbage) printf 'this is not json\n'; exit 0 ;;
    schema2) printf '{"schema":2}\n'; exit 0 ;;
  esac
}

stub_env_probe() {
  [ ! -e "$TB_AGG/env-probe" ] || env | sed 's/=.*//' | LC_ALL=C sort > "$TB_AGG/env.$1"
}

# stub_deliver <apply-function>: one action record on stdin, one outcome line out.
stub_deliver() {
  local record step outcome
  IFS= read -r record
  printf '%s\n' "$record" >> "$TB_AGG/received.jsonl"
  stub_log deliver "$(jq -r .id <<< "$record")" "$(jq -r .kind <<< "$record")"
  step='{"outcome":"delivered"}'
  if [ -s "$TB_AGG/play" ]; then
    IFS= read -r step < "$TB_AGG/play"
    tail -n +2 "$TB_AGG/play" > "$TB_AGG/play.next"
    mv "$TB_AGG/play.next" "$TB_AGG/play"
  fi
  case "$step" in
    sleep\ *)
      step=${step#sleep }
      sleep "${step%% *}"
      step=${step#* }
      ;;
  esac
  outcome=$(jq -r .outcome <<< "$step")
  [ "$outcome" != delivered ] || "$1" "$record"
  printf '%s\n' "$step"
}

# stub_apply_tag <report-file> <record>: a delivered tag shows in the next report.
stub_apply_tag() {
  local file=$1 record=$2 tmp
  [ "$(jq -r .kind <<< "$record")" = tag ] || return 0
  [ -f "$file" ] || return 0
  tmp="$file.tmp"
  jq --argjson r "$record" '.topics[$r.task] = ((.topics[$r.task] // "") + (if (.topics[$r.task] // "") == "" then "" else "\n" end) + $r.topic + " 2026-11-19T12:00:00Z")' \
    "$file" > "$tmp"
  mv "$tmp" "$file"
}
