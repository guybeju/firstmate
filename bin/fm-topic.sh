#!/usr/bin/env bash
# fm-topic.sh - what is left of the board's old command name.
#
# Usage: fm-topic.sh <the arguments of an old call>
#
# The board's command is bin/myshape.sh now. This stand-in runs nothing and
# writes nothing: it exits 2 with one line naming the command that has the
# call now, so a session whose rules were loaded before the rename finds its
# way in one turn. The forms that moved to Firstmate's own commands (tag,
# --in-home, setup, install-rules, order, and split with tasks) name
# bin/fm-board.sh or bin/fm-dispatch-plan.sh; anything else names
# bin/myshape.sh with the same arguments.
#
# A second line says what the user has to run, when this home has not been
# moved to the new names yet (bin/fm-board.sh migrate-myshape) or its
# data/captain.md still holds the rules block with the old marker
# (bin/fm-board.sh install-rules); otherwise it says the session's rules are
# older than the home's and the session has to restart.
#
# Kept only until no home has old names left; it goes with the other pieces of
# the move.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# How many words of a split are not options or option values: the source
# topic, the new name, and any task the caller wanted moved along.
split_word_count() {
  local count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --goal | --id | --reason) shift ;;
      --*) ;;
      *) count=$((count + 1)) ;;
    esac
    [ "$#" -eq 0 ] || shift
  done
  printf '%s\n' "$count"
}

# The line naming the command that has <subcommand> <arguments...> now.
new_command_line() {
  local sub=${1:-}
  [ "$#" -eq 0 ] || shift
  case "$sub" in
    tag) printf '%s\n' "改名了：tag 改用 bin/fm-board.sh tag <task-id> <議題 id>" ;;
    --in-home) printf '%s\n' "改名了：--in-home 改用 bin/fm-board.sh --in-home <id> <tag|answers|setup> …" ;;
    setup) printf '%s\n' "改名了：setup 改用 bin/fm-board.sh setup" ;;
    install-rules) printf '%s\n' "改名了：install-rules 改用 bin/fm-board.sh install-rules" ;;
    order) printf '%s\n' "改名了：order 改用 bin/fm-dispatch-plan.sh order" ;;
    split)
      if [ "$(split_word_count "$@")" -gt 2 ]; then
        printf '%s\n' "改名了：要一起搬 task 的 split 改用 bin/fm-board.sh split <議題 id> <新名稱> --goal <一行> <task…>"
      else
        printf '%s\n' "改名了：改用 bin/myshape.sh <同樣的參數>"
      fi
      ;;
    *) printf '%s\n' "改名了：改用 bin/myshape.sh <同樣的參數>" ;;
  esac
}

# unmoved <old path> <new path>: 0 when the old path is still there and the new one is not.
unmoved() {
  [ -e "$1" ] && [ ! -e "$2" ]
}

# What the user has to run before the new command works in this session.
next_step_line() {
  if unmoved "$STATE/topic-board" "$STATE/myshape" || unmoved "$DATA/topic-board" "$DATA/myshape" ||
    unmoved "$CONFIG/topic-board-port" "$CONFIG/myshape-port"; then
    printf '%s\n' "這個 home 還沒搬：請使用者跑 bin/fm-board.sh migrate-myshape"
  elif [ -f "$DATA/captain.md" ] && grep -q '^[[:space:]]*<!-- topic-board:begin' "$DATA/captain.md"; then
    printf '%s\n' "規則還是舊的：請使用者重跑 bin/fm-board.sh install-rules，再重開 session"
  else
    printf '%s\n' "這個 session 載入的規則還是舊的：請使用者重開 session"
  fi
}

{
  new_command_line "$@"
  next_step_line
} >&2
exit 2
