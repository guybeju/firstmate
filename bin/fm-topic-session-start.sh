#!/usr/bin/env bash
# fm-topic-session-start.sh - the topic board's line in the session-start digest.
#
# Usage: fm-topic-session-start.sh
#
# bin/fm-session-start.sh runs this once per full session start that holds the
# session lock; a lock-refused session and a context re-emit never run it. It
# makes sure the board service of this home is running and prints exactly one
# line saying what it found:
#
#   看板服務：在跑
#   看板服務：原本沒在跑，已啟動
#   看板服務：原本沒有回應，已重新啟動
#   看板服務：無法啟動：<原因>
#
# It prints nothing and starts nothing when this home does not use the board:
# in a secondmate home, and in a main home without state/topic-board/token.
# The service writes that token the first time it starts successfully and
# never deletes it (stop keeps it), while fm-board.sh setup and install-rules
# and a start that failed leave none, so the token marks a main home whose
# board has run.
#
# A running board is left alone, even one running older code: the next board
# command replaces that one (fm-topic.sh open). A board that is not running,
# including one stopped on purpose with fm-topic.sh stop, is started.
#
# Costs: one fm-topic.sh status when the board is running. Otherwise also one
# fm-topic.sh open, whose stdout carries the board's access token and is
# discarded unread. status is bounded at STATUS_BOUND seconds and open at
# START_BOUND seconds, which covers replacing a hung board (a 3-second health
# check twice, a 5-second kill grace, 10 seconds for readiness). A longer wait,
# such as another command holding the board's start lock for up to 30 seconds,
# is reported as a start that did not finish in time. The reason on a failure is the first line of open's stderr
# without its framing, so a multi-line reason still prints as one line.
#
# Always exits 0: this is a report, not a gate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STATUS_BOUND=10
START_BOUND=30
RUNNING_LINE='看板服務：在跑'
HUNG_LINE='看板服務：沒有回應'

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# The one-line reason in open's stderr <text>, given its exit code <rc>.
start_failure_reason() {  # <rc> <text>
  local rc=$1 reason
  if fm_timed_out "$rc"; then
    printf '%s\n' "${START_BOUND} 秒內沒有啟動完成，跑 bin/fm-topic.sh status 看狀況"
    return 0
  fi
  IFS= read -r reason <<< "$2" || true
  reason=${reason#看板服務無法啟動：}
  reason=${reason%這次的要求沒有寫入。}
  reason=${reason%，最後幾行：}
  [ -n "$reason" ] || reason="fm-topic.sh open 結束碼 ${rc}，沒有說原因"
  printf '%s\n' "$reason"
}

main() {
  local status_out first err rc=0
  fm_root_is_secondmate_home "$FM_HOME" && return 0
  [ -f "$STATE/topic-board/token" ] || return 0
  status_out=$(fm_run_timed "$STATUS_BOUND" "$SCRIPT_DIR/fm-topic.sh" status 2>/dev/null) || true
  IFS= read -r first <<< "$status_out" || true
  if [ "$first" = "$RUNNING_LINE" ]; then
    printf '%s\n' "$RUNNING_LINE"
    return 0
  fi
  err=$(fm_run_timed "$START_BOUND" "$SCRIPT_DIR/fm-topic.sh" open 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "看板服務：無法啟動：$(start_failure_reason "$rc" "$err")"
  elif [ "$first" = "$HUNG_LINE" ]; then
    printf '%s\n' '看板服務：原本沒有回應，已重新啟動'
  else
    printf '%s\n' '看板服務：原本沒在跑，已啟動'
  fi
}

main
exit 0
