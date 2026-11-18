#!/usr/bin/env bash
# fm-topic.sh - the topic board's command.
#
# Usage:
#   fm-topic.sh list [--all] [--json]
#   fm-topic.sh create <name> --goal <one line> [--id <id>] [--queue high|normal|later]
#   fm-topic.sh merge <old-topic-id> <new-topic-id> [--reason <one line>]
#   fm-topic.sh close-propose <topic-id> --reason <text>
#   fm-topic.sh move <topic-id> <queue> [--before <topic-id> | --first]
#   fm-topic.sh rename <topic-id> <name>
#   fm-topic.sh split <topic-id> <name> --goal <one line> [--id <new-id>] [--reason <one line>]
#   fm-topic.sh goal <topic-id> <one line>
#   fm-topic.sh archive <topic-id>
#   fm-topic.sh reopen <topic-id> [--queue <queue>]
#   fm-topic.sh summary [--home <secondmate-id>] <task-id> <ready|report|failed|landed> -
#   fm-topic.sh retract [--home <secondmate-id>] <task-id> <ready|report|failed|landed> -
#   fm-topic.sh which [--home <secondmate-id>] <task-id>
#   fm-topic.sh find [--all] <keyword>
#   fm-topic.sh todo add <task-id> <title> --topic <topic-id> --do <one line> [--note <text>] [--cmd <command>]...
#   fm-topic.sh todo done <task-id>
#   fm-topic.sh todo failed <task-id> --reason <one line>
#   fm-topic.sh todo obsolete <task-id> --reason <one line>
#   fm-topic.sh open | status | stop | restart | reset-token
#
# Every subcommand except open runs only in a home where the board has run:
# one with state/topic-board/token, which the service writes the first time it
# starts and never deletes. Anywhere else it is refused with exit 1 and nothing
# is written; open starts a board there.
#
# list only reads files; it does not need the board service, so it keeps
# working when the service is down. Every other subcommand talks to the board
# service over its Unix socket and, except for status and stop, starts the
# service first when it is not running. They need node 22 or newer. Repeating
# any of them unchanged is safe.
#
# create makes a topic that is confirmed at once and last in its queue:
# normal unless --queue names another. A live topic with the same name and
# goal is the same topic, so a repeat prints its id and leaves it where it is.
#
# open prints the board's URL. status and stop never start the service, but
# the main home's next session start does.
#
# summary stores a one-to-three sentence milestone summary read from stdin (at
# most 600 characters) and prints the line to start the chat reminder with:
# "<topic name>：", "未分類：" when the task has no topic, or "議題不明（<task-id>）："
# when the task's home could not be read. which prints the same line without
# storing anything. --home names the secondmate home the task lives in.
#
# split makes a new confirmed topic out of part of <topic-id>, right after it
# in the same queue. It moves no task; a split that names tasks is refused.
#
# find answers where a topic or task is now and how it got there, in a few
# lines: it matches the keyword against topic ids, names, and goals, including
# ids and names that were merged away or renamed, and prints each match under
# its current id with its history. A keyword that is a task id also prints the
# topics that task was tagged with, oldest first. Each history line says, when
# it was recorded, whether the change was made on the page or by a command and
# why: the --reason given with a merge or split, or the close proposal an
# archive followed. The answer is kept short; --all prints every matching
# topic and every history line with exact times, for working out what went
# wrong with a topic.
#
# todo keeps the things the captain has to do by hand (a sudo command, a
# login) on the board. add holds <task-id> for the captain, creating it when it
# does not exist, and tags it with the topic. --do says what to do, in one
# line; --note is optional guidance shown as plain text; each --cmd is one
# command, shown exactly as written in its own block with its own copy button.
# A command of several lines (a here-document, a line continuation) is one
# --cmd, for example --cmd "$(cat <<'EOF' ... EOF)". An item with no --cmd
# shows no command. add reads no stdin: the old "-" form is refused. In the
# hold reason every line after the action carries a label (說明：, 指令：, or
# 續： for a further line of a command); a reason with an unlabelled line was
# written before the labels and is shown as it always was, everything after
# its first line in one block. The page offers 做完了 and 不做了. 做完了 does not
# close the item: the board tells firstmate, who checks and then runs done
# (which closes it) or failed (which puts it back in front of the captain with
# the reason). obsolete marks an item firstmate no longer needs; the captain
# takes it down with one click, so the closing record stays the captain's own
# word. Main home only. Repeating add, failed, or obsolete unchanged is safe;
# done on an item that is already closed changes nothing and says so.
#
# retract takes the task's latest summary of that kind off the board when it
# turned out to be wrong; stdin is the reason. The line stays in the file.
#
# tag, setup, order, install-rules, --in-home, and split with tasks are no
# longer this command's: each of those old forms exits 2 with one line naming
# the command that has it now, and writes nothing.
#
# Exit codes: 0 success (including an identical repeat), 1 refused or failed
# with nothing written, 2 usage error, 3 outcome unknown (the request was sent
# but no answer came back; repeat it once), 69 the board service is unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-topic.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BOARD_DIST="$FM_ROOT/topic-board/dist"
DEFAULT_PORT=47819
EXIT_UNAVAILABLE=69
TOPICS_FILE="$DATA/topics.json"
ARCHIVE_FILE="$DATA/topics-archive.json"
TODO_MARKER='動手：'

# shellcheck source=bin/fm-topic-lib.sh
. "$SCRIPT_DIR/fm-topic-lib.sh"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

usage_error() {
  printf '%s\n' "fm-topic.sh: $*（fm-topic.sh --help 看用法）" >&2
  exit 2
}

# Every subcommand but open needs a home whose board has run: the service
# writes state/topic-board/token the first time it starts and never deletes it.
require_board() {
  [ -f "$STATE/topic-board/token" ] ||
    tb_die 1 "這裡沒有看板（找不到 state/topic-board/token）；要在這裡開看板先跑 fm-topic.sh open。"
}

require_jq() {
  command -v jq >/dev/null 2>&1 ||
    tb_die 1 "$1 需要 jq，但找不到。安裝：$(tb_jq_install_hint)"
}

cmd_list() {
  local all=0 json=0 archive
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --json) json=1 ;;
      *) usage_error "list 不認得的參數：$1" ;;
    esac
    shift
  done
  require_jq list
  if [ ! -f "$TOPICS_FILE" ]; then
    if [ "$json" -eq 1 ]; then printf '[]\n'; else printf '%s\n' "還沒有議題。"; fi
    return 0
  fi
  archive=$ARCHIVE_FILE
  if [ "$all" -eq 0 ] || [ ! -f "$archive" ]; then
    archive=/dev/null
  fi
  jq -r -n --argjson json "$json" --slurpfile live "$TOPICS_FILE" --slurpfile gone "$archive" '
    $live[0] as $doc
    | [ ("high", "normal", "later") as $queue
        | ($doc.queues[$queue] // []) | to_entries[]
        | {id: .value, status: "confirmed", queue: $queue, position: (.key + 1),
           name: ($doc.topics[.value].name // "")} ] as $queued
    | [ $queued[].id ] as $placed
    | [ $doc.topics | to_entries[] | .key as $id | select($placed | index([$id]) | not)
        | {id: .key, status: "confirmed", queue: null, position: null, name: .value.name} ] as $loose
    | [ ($gone[0].topics // {}) | to_entries[]
        | {id: .key, status: "archived", queue: null, position: null, name: .value.name} ] as $archived
    | ($queued + $loose + $archived) as $rows
    | if $json == 1 then $rows
      elif ($rows | length) == 0 then "還沒有議題。"
      else $rows[] | "\(.id)\t\(.status)\t\(.queue // "-")\t\(.position // "-")\t\(.name)"
      end
  ' 2>/dev/null || tb_die 1 "讀不懂 $TOPICS_FILE 或 ${ARCHIVE_FILE}。"
}

# What <task-id> is in this home: "todo" for an open hands-on item, "other"
# for any other open captain hold, "task" for a task that is not held for the
# captain, "none" when the backlog and the fleet know no such task.
todo_kind() {
  local report
  report=$("$SCRIPT_DIR/fm-topic-board-read.sh" 0 -) || tb_die 1 "讀不到這個 home 的 backlog，沒有改任何東西。"
  printf '%s' "$report" | jq -r --arg id "$1" --arg marker "$TODO_MARKER" '
    ([.holds[] | select(.id == $id)][0]) as $hold
    | if $hold != null then (if ($hold.question | startswith($marker)) then "todo" else "other" end)
      elif ([.queued[], .tasks[] | select(.id == $id)] | length) > 0 then "task"
      else "none" end'
}

# todo_lines <first-label> <next-label> <text>: <text> one label per line,
# <first-label> on its first line and <next-label> on the rest, each line
# after a newline. Line contents are kept byte for byte.
todo_lines() {
  local label=$1 next=$2 rest=$3 nl=$'\n' out="" line
  while :; do
    case "$rest" in
      *"$nl"*)
        line=${rest%%"$nl"*}
        out+="$nl$label$line"
        rest=${rest#*"$nl"}
        ;;
      *)
        out+="$nl$label$rest"
        break
        ;;
    esac
    label=$next
  done
  printf '%s' "$out"
}

# todo_part <flag> <value>: <value> with carriage returns and trailing newlines
# removed. A value with nothing else in it is a usage error.
todo_part() {
  local value=${2//$'\r'/}
  while [ "${value%$'\n'}" != "$value" ]; do value=${value%$'\n'}; done
  [ -n "${value//[[:space:]]/}" ] || usage_error "$1 後面要有內容"
  printf '%s' "$value"
}

TODO_ADD_USAGE='todo add 的用法是 <task-id> <標題> --topic <議題 id> --do <要做什麼> [--note <說明>] [--cmd <指令>]…：每個要使用者跑的指令一個 --cmd（多行的指令整段放進同一個 --cmd），不是指令的說明放 --note'

# todo add <task-id> <title> --topic <topic-id> --do <action> [--note <text>]
# [--cmd <command>]...: put a hands-on item for the captain on the board. The
# topic is checked before anything is written.
todo_add() {
  local topic="" action="" note="" text kind command
  local -a words=() commands=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --topic | --do | --note | --cmd)
        [ "$#" -ge 2 ] || usage_error "$1 後面要有值。$TODO_ADD_USAGE"
        case "$1" in
          --topic) topic=$2 ;;
          --do)
            [ -z "$action" ] || usage_error "--do 只能有一個。$TODO_ADD_USAGE"
            action=$(todo_part --do "$2")
            ;;
          --note)
            [ -z "$note" ] || usage_error "--note 只能有一個；多行的說明放進同一個 --note。$TODO_ADD_USAGE"
            note=$(todo_part --note "$2")
            ;;
          --cmd) commands+=("$(todo_part --cmd "$2")") ;;
        esac
        shift 2
        ;;
      -) usage_error "todo add 不再從 stdin 讀內容；要做什麼放 --do，說明放 --note，指令放 --cmd。$TODO_ADD_USAGE" ;;
      --*) usage_error "todo add 不認得 ${1}。$TODO_ADD_USAGE" ;;
      *)
        words+=("$1")
        shift
        ;;
    esac
  done
  if [ "${#words[@]}" -ne 2 ] || [ -z "$topic" ] || [ -z "$action" ]; then
    usage_error "$TODO_ADD_USAGE"
  fi
  case "$action" in
    *$'\n'*) usage_error "--do 只寫一行；其餘的說明放 --note，指令放 --cmd。$TODO_ADD_USAGE" ;;
  esac
  tb_valid_id "${words[0]}" || usage_error "task id 格式不對：${words[0]}"
  tb_valid_id "$topic" || usage_error "議題 id 格式不對：$topic"
  # The labels are what the board reads the parts by (TODO_LABELS in topic-board/src/view.ts).
  text="$TODO_MARKER$action"
  [ -z "$note" ] || text+=$(todo_lines '說明：' '說明：' "$note")
  for command in ${commands[@]+"${commands[@]}"}; do
    text+=$(todo_lines '指令：' '續：' "$command")
  done
  topic=$(tb_topic_for_tag "$TOPICS_FILE" "$topic")
  kind=$(todo_kind "${words[0]}")
  [ "$kind" != other ] ||
    tb_die 1 "${words[0]} 已經是等使用者決定的項目，不能改成要使用者動手的項目。"
  [ "$kind" != task ] ||
    tb_die 1 "${words[0]} 已經是一件工作，不能改成要使用者動手的項目；換一個 task id。"
  # Bring the board onto this code before the item is written, so a board still
  # running older code never shows the labelled text as one command.
  "$SELF" open >/dev/null || exit $?
  # A hands-on item holds only the captain's own action, so answering it closes it.
  # todo add reads no stdin, so the caller's stdin is not handed on either.
  "$SCRIPT_DIR/fm-captain-hold.sh" hold "${words[0]}" --title "${words[1]}" --reason "$text" \
    --on-answer close </dev/null >/dev/null || tb_die 1 "沒有建立 ${words[0]}；修好上面的問題後原樣再跑一次。"
  "$SCRIPT_DIR/fm-board.sh" tag "${words[0]}" "$topic" >/dev/null ||
    tb_die 1 "${words[0]} 已建立但沒有標上議題；原樣再跑一次同一個指令。"
  # A rewritten item starts over: what the captain or firstmate said about the old text no longer holds.
  if [ -f "$TOPICS_FILE" ] && jq -e --arg id "${words[0]}" '(.todos // {}) | objects | has($id)' "$TOPICS_FILE" >/dev/null 2>&1; then
    "$SELF" todo-clear "${words[0]}" >/dev/null ||
      tb_die 1 "${words[0]} 已更新，但看板上舊的狀態沒有清掉；原樣再跑一次同一個指令。"
  fi
  printf '%s\n' "ok ${words[0]} 已放上看板的「要你動手」（議題 ${topic}）"
}

# todo done <task-id>: firstmate checked that the captain did it; close the item.
todo_done() {
  local id=${1:-} kind out
  [ "$#" -eq 1 ] || usage_error "todo done 的用法是 <task-id>"
  tb_valid_id "$id" || usage_error "task id 格式不對：$id"
  kind=$(todo_kind "$id")
  # Only an open hands-on item is fed to the intake: it would close any captain hold it is given.
  [ "$kind" = todo ] ||
    tb_die 1 "$id 不是開著的「要你動手」項目，沒有關任何東西（已經關過的話不用再跑）。"
  out=$(printf '%s\t做完了\tfirst mate 已驗證\tdone\n' "$id" |
    "$SCRIPT_DIR/fm-captain-hold.sh" answers --source topic-board) ||
    tb_die 1 "$id 沒有關：$(printf '%s' "$out" | head -n 1)"
  printf '%s\n' "ok $id 已關（做完了，first mate 已驗證）"
}

cmd_todo() {
  local sub=${1:-}
  [ "$#" -gt 0 ] || usage_error "todo 的用法是 add、done、failed、obsolete 其中之一"
  shift
  case "$sub" in
    add)
      require_jq "todo add"
      todo_add "$@"
      ;;
    done)
      require_jq "todo done"
      todo_done "$@"
      ;;
    failed | obsolete) cmd_service "todo-$sub" "$@" ;;
    *) usage_error "todo 不認得 ${sub}；可用的是 add、done、failed、obsolete" ;;
  esac
}

service_unavailable() {  # <reason> <fix>
  printf '%s\n' "看板服務無法啟動：$1。$2。這次的要求沒有寫入。" >&2
  exit "$EXIT_UNAVAILABLE"
}

# The port the board should listen on: config/topic-board-port, or the default.
configured_port() {
  local port=$DEFAULT_PORT
  if [ -f "$CONFIG/topic-board-port" ]; then
    IFS= read -r port < "$CONFIG/topic-board-port" || true
    case "$port" in
      '' | *[!0-9]*) port=0 ;;
    esac
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
      service_unavailable "config/topic-board-port 不是 1024 到 65535 的埠號" "改成合法的埠號，或刪掉那個檔用預設的 $DEFAULT_PORT"
    fi
  fi
  printf '%s\n' "$port"
}

# What status can still say when node is missing: only what the files show.
status_without_node() {
  local file
  printf '%s\n' "看板服務：不明（沒有 node，無法詢問服務）"
  for file in pid port; do
    if [ -f "$STATE/topic-board/$file" ]; then
      printf '上次的 %s：%s\n' "$file" "$(< "$STATE/topic-board/$file")"
    fi
  done
  for file in "$DATA/topic-board/events.jsonl" "$DATA/topic-board/summaries.jsonl" "$STATE/topic-board/audit.jsonl"; do
    if [ -f "$file" ]; then
      printf '%s：%s 位元組\n' "${file##*/}" "$(wc -c < "$file" | tr -d ' ')"
    fi
  done
}

# Hand a socket subcommand to the node client, after the checks that must not
# need node themselves.
cmd_service() {
  local sub=$1 port commit major
  if ! command -v node >/dev/null 2>&1; then
    if [ "$sub" = status ]; then
      status_without_node
      return 0
    fi
    service_unavailable "沒有 node" "安裝：brew install node  # or the platform's package manager"
  fi
  major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')
  case "$major" in '' | *[!0-9]*) major=0 ;; esac
  [ "$major" -ge 22 ] || service_unavailable "node 版本低於 22" "請升級到 22 以上"
  if [ ! -f "$BOARD_DIST/board-client.js" ] || [ ! -f "$BOARD_DIST/board-server.js" ]; then
    service_unavailable "編譯結果不見了（${BOARD_DIST}）" "確認 checkout 完整"
  fi
  port=$(configured_port)
  commit=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')
  exec node "$BOARD_DIST/board-client.js" --home "$FM_HOME" --root "$FM_ROOT" --commit "$commit" \
    --port "$port" --state "$STATE" --data "$DATA" -- "$@"
}

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

# The forms this command no longer has: one line naming the command that has
# them now, exit 2, nothing written. None of them needs the board to exist.
refuse_old_form() {  # <subcommand> <arguments...>
  local sub=$1
  shift
  case "$sub" in
    tag) usage_error "沒有 tag 了：改用 bin/fm-board.sh tag <task-id> <議題 id>" ;;
    --in-home) usage_error "沒有 --in-home 了：改用 bin/fm-board.sh --in-home <id> <tag|answers|setup> …" ;;
    setup) usage_error "沒有 setup 了：改用 bin/fm-board.sh setup" ;;
    install-rules) usage_error "沒有 install-rules 了：改用 bin/fm-board.sh install-rules" ;;
    order) usage_error "沒有 order 了：改用 bin/fm-dispatch-plan.sh order" ;;
    split)
      [ "$(split_word_count "$@")" -le 2 ] ||
        usage_error "split 只建議題；要一起搬 task，改用 bin/fm-board.sh split <議題 id> <新名稱> --goal <一行> <task…>"
      ;;
    # The board confirms every topic it makes; rules from before that still name these.
    propose | confirm) usage_error "沒有 ${sub} 了：議題一建立就已確認。新議題用 create <名稱> --goal <一行>" ;;
  esac
}

main() {
  [ "$#" -gt 0 ] || usage_error "少了子命令"
  local sub=$1
  shift
  refuse_old_form "$sub" "$@"
  case "$sub" in
    -h | --help)
      usage
      return 0
      ;;
    # todo-clear is internal: it forgets a hands-on item's mark after its text was rewritten.
    open | list | todo | todo-clear | split | create | merge | close-propose | move | rename | \
      goal | archive | reopen | summary | retract | which | find | status | stop | restart | reset-token) ;;
    *) usage_error "不認得的子命令：$sub" ;;
  esac
  [ "$sub" = open ] || require_board
  case "$sub" in
    list) cmd_list "$@" ;;
    todo) cmd_todo "$@" ;;
    *) cmd_service "$sub" "$@" ;;
  esac
}

main "$@"
