#!/usr/bin/env bash
# myshape.sh - the topic board's command.
#
# Usage:
#   myshape.sh list [--all] [--json]
#   myshape.sh create <name> --goal <one line> [--id <id>] [--queue high|normal|later]
#   myshape.sh merge <old-topic-id> <new-topic-id> [--reason <one line>]
#   myshape.sh close-propose <topic-id> --reason <text>
#   myshape.sh move <topic-id> <queue> [--before <topic-id> | --first]
#   myshape.sh rename <topic-id> <name>
#   myshape.sh split <topic-id> <name> --goal <one line> [--id <new-id>] [--reason <one line>]
#   myshape.sh goal <topic-id> <one line>
#   myshape.sh archive <topic-id>
#   myshape.sh reopen <topic-id> [--queue <queue>]
#   myshape.sh summary [--home <secondmate-id>] <task-id> <ready|report|failed|landed> -
#   myshape.sh retract [--home <secondmate-id>] <task-id> <ready|report|failed|landed> -
#   myshape.sh which [--home <secondmate-id>] <task-id>
#   myshape.sh find [--all] <keyword>
#   myshape.sh todo add <task-id> <title> --topic <topic-id> --do <one line> [--note <text>] [--cmd <command>]... [--ref <text>] [--captain-closes]
#   myshape.sh todo add <task-id> <title> [--topic <topic-id>] --do <one line> ... --adopt [--since <time>]
#   myshape.sh todo done <task-id>
#   myshape.sh todo failed <task-id> --reason <one line>
#   myshape.sh todo obsolete <task-id> --reason <one line>
#   myshape.sh todo adopt-done [<task-id>]...
#   myshape.sh open | status | stop | restart | reset-token
#
# Every subcommand except open runs only in a home where the board has run:
# one with state/myshape/token, which the service writes the first time it
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
# login) on the board, which stores each item itself in data/myshape/todos.json.
# add puts <task-id> on the board under a live topic, or rewrites it; a
# rewrite of different text starts it over as still to do. --do says what to
# do, in one line; --note is optional guidance shown as plain text; each --cmd
# is one command, shown exactly as written in its own block with its own copy
# button. A command of several lines (a here-document, a line continuation) is
# one --cmd, for example --cmd "$(cat <<'EOF' ... EOF)". An item with no --cmd
# shows no command. add reads no stdin: the old "-" form is refused. --ref is
# opaque text of at most 128 characters that the board hands back in its
# notices about the item. The page offers 做完了 and 不做了. 做完了 does not close
# the item: the board tells the aggregator, who checks and then runs done
# (which closes it) or failed (which puts it back in front of the captain with
# the reason). obsolete takes an item the aggregator no longer needs off the
# page at once, with the reason in its topic's updates; an item added with
# --captain-closes waits instead for the captain's 好，撤下.
#
# --adopt is for items an aggregator kept before the board kept them: it
# accepts an archived topic, an unknown one or none, keeps the mark such an
# item already had, and changes nothing for an item already on the board or
# one closed on the board whose hold is still open; --since is when the item
# was first opened, an ISO 8601 time. adopt-done ends such a pass: given every
# such item still open on the aggregator's side, it drops the marks of the
# others and takes adopted items (--ref hold) that are no longer open off the
# page, with a record and no notice.
#
# Every step of an item (put on, rewritten, adopted, claimed, failed, marked no
# longer needed, closed) writes a record on its topic's updates saying who made
# it: the captain on the page, or the aggregator by its label.
#
# Repeating add, failed, or obsolete unchanged is safe; done on an item that
# is already closed changes nothing and says so.
#
# retract takes the task's latest summary of that kind off the board when it
# turned out to be wrong; stdin is the reason. The line stays in the file.
#
# split with tasks is not this command's: it exits 2 with one line naming the
# command that has it, and writes nothing.
#
# Until a home is moved to this command's names, every subcommand there is
# refused with exit 69 and nothing is written: a home that still has
# state/topic-board, data/topic-board, or config/topic-board-port while the new
# name beside it is missing is moved first, by the command the refusal names.
#
# Exit codes: 0 success (including an identical repeat), 1 refused or failed
# with nothing written, 2 usage error, 3 outcome unknown (the request was sent
# but no answer came back; repeat it once), 69 the board service is unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BOARD_DIST="$FM_ROOT/myshape/dist"
DEFAULT_PORT=47819
EXIT_UNAVAILABLE=69
TOPICS_FILE="$DATA/topics.json"
ARCHIVE_FILE="$DATA/topics-archive.json"

# shellcheck source=bin/myshape-lib.sh
. "$SCRIPT_DIR/myshape-lib.sh"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

usage_error() {
  printf '%s\n' "myshape.sh: $*（myshape.sh --help 看用法）" >&2
  exit 2
}

# The board's paths from before the rename. A home holding one of them while
# its new name is missing has not been moved yet; the board runs nowhere near
# it, so that a stray command never starts a second, empty board beside the
# old data.
refuse_unmoved() {  # <old path> <new path>
  if [ -e "$1" ] && [ ! -e "$2" ]; then
    service_unavailable "這個 home 還有改名前的 $1" "先跑 bin/fm-board.sh migrate-myshape 搬到新名字"
  fi
}

require_moved() {
  refuse_unmoved "$STATE/topic-board" "$STATE/myshape"
  refuse_unmoved "$DATA/topic-board" "$DATA/myshape"
  refuse_unmoved "$CONFIG/topic-board-port" "$CONFIG/myshape-port"
}

# Every subcommand but open needs a home whose board has run: the service
# writes state/myshape/token the first time it starts and never deletes it.
require_board() {
  [ -f "$STATE/myshape/token" ] ||
    tb_die 1 "這裡沒有看板（找不到 state/myshape/token）；要在這裡開看板先跑 myshape.sh open。"
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
# [--cmd <command>]... [--ref <text>] [--captain-closes] [--adopt]: put a
# hands-on item for the captain on the board. The board checks the topic.
todo_add() {
  local topic="" action="" note="" ref="" since="" captain_closes=false adopt=false item
  local -a words=() commands=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --topic | --do | --note | --cmd | --ref | --since)
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
          --ref) ref=$2 ;;
          --since) since=$2 ;;
        esac
        shift 2
        ;;
      --captain-closes) captain_closes=true && shift ;;
      --adopt) adopt=true && shift ;;
      -) usage_error "todo add 不再從 stdin 讀內容；要做什麼放 --do，說明放 --note，指令放 --cmd。$TODO_ADD_USAGE" ;;
      --*) usage_error "todo add 不認得 ${1}。$TODO_ADD_USAGE" ;;
      *)
        words+=("$1")
        shift
        ;;
    esac
  done
  if [ "${#words[@]}" -ne 2 ] || { [ -z "$topic" ] && [ "$adopt" = false ]; } || [ -z "$action" ]; then
    usage_error "$TODO_ADD_USAGE"
  fi
  case "$action" in
    *$'\n'*) usage_error "--do 只寫一行；其餘的說明放 --note，指令放 --cmd。$TODO_ADD_USAGE" ;;
  esac
  tb_valid_id "${words[0]}" || usage_error "task id 格式不對：${words[0]}"
  [ -z "$topic" ] || tb_valid_id "$topic" || usage_error "議題 id 格式不對：$topic"
  [ -z "$since" ] || [ "$adopt" = true ] || usage_error "--since 只給 --adopt 用。$TODO_ADD_USAGE"
  item=$(jq -cn --arg id "${words[0]}" --arg title "${words[1]}" --arg topic "$topic" \
    --arg action "$action" --arg guidance "$note" --arg ref "$ref" --arg since "$since" \
    --argjson captain_closes "$captain_closes" --argjson adopt "$adopt" \
    '{id: $id, title: $title, topic: (if $topic == "" then null else $topic end), action: $action,
      guidance: $guidance, commands: $ARGS.positional, ref: $ref,
      captain_closes: $captain_closes, adopt: $adopt}
     + (if $since == "" then {} else {since: $since} end)' \
    --args ${commands[@]+"${commands[@]}"}) || tb_die 1 "組不出項目的內容，沒有放上任何東西。"
  printf '%s' "$item" | cmd_service todo-add -
}

cmd_todo() {
  local sub=${1:-}
  [ "$#" -gt 0 ] || usage_error "todo 的用法是 add、done、failed、obsolete、adopt-done 其中之一"
  shift
  case "$sub" in
    add)
      require_jq "todo add"
      todo_add "$@"
      ;;
    done | failed | obsolete | adopt-done) cmd_service "todo-$sub" "$@" ;;
    *) usage_error "todo 不認得 ${sub}；可用的是 add、done、failed、obsolete、adopt-done" ;;
  esac
}

service_unavailable() {  # <reason> <fix>
  printf '%s\n' "看板服務無法啟動：$1。$2。這次的要求沒有寫入。" >&2
  exit "$EXIT_UNAVAILABLE"
}

# The port the board should listen on: config/myshape-port, or the default.
configured_port() {
  local port=$DEFAULT_PORT
  if [ -f "$CONFIG/myshape-port" ]; then
    IFS= read -r port < "$CONFIG/myshape-port" || true
    case "$port" in
      '' | *[!0-9]*) port=0 ;;
    esac
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
      service_unavailable "config/myshape-port 不是 1024 到 65535 的埠號" "改成合法的埠號，或刪掉那個檔用預設的 $DEFAULT_PORT"
    fi
  fi
  printf '%s\n' "$port"
}

# What status can still say when node is missing: only what the files show.
status_without_node() {
  local file
  printf '%s\n' "看板服務：不明（沒有 node，無法詢問服務）"
  for file in pid port; do
    if [ -f "$STATE/myshape/$file" ]; then
      printf '上次的 %s：%s\n' "$file" "$(< "$STATE/myshape/$file")"
    fi
  done
  for file in "$DATA/myshape/events.jsonl" "$DATA/myshape/summaries.jsonl" "$STATE/myshape/audit.jsonl"; do
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
    open | list | todo | split | create | merge | close-propose | move | rename | \
      goal | archive | reopen | summary | retract | which | find | status | stop | restart | reset-token) ;;
    *) usage_error "不認得的子命令：$sub" ;;
  esac
  require_moved
  [ "$sub" = open ] || require_board
  case "$sub" in
    list) cmd_list "$@" ;;
    todo) cmd_todo "$@" ;;
    *) cmd_service "$sub" "$@" ;;
  esac
}

main "$@"
