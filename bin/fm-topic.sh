#!/usr/bin/env bash
# fm-topic.sh - the topic board's command for firstmate and the captain.
#
# Usage:
#   fm-topic.sh tag <task-id> <topic-id>
#   fm-topic.sh tag <new-task-id> --from <old-task-id>
#   fm-topic.sh list [--all] [--json]
#   fm-topic.sh order
#   fm-topic.sh setup
#   fm-topic.sh --in-home <secondmate-id> tag <task-id> <topic-id>
#   fm-topic.sh --in-home <secondmate-id> answers        (one answer line on stdin)
#   fm-topic.sh --in-home <secondmate-id> setup
#   fm-topic.sh create <name> --goal <one line> [--id <id>] [--queue high|normal|later]
#   fm-topic.sh merge <old-topic-id> <new-topic-id> [--reason <one line>]
#   fm-topic.sh close-propose <topic-id> --reason <text>
#   fm-topic.sh move <topic-id> <queue> [--before <topic-id> | --first]
#   fm-topic.sh rename <topic-id> <name>
#   fm-topic.sh split <topic-id> <name> --goal <one line> [--id <new-id>] [--reason <one line>] [<task-id> | <secondmate-id>/<task-id>]...
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
#   fm-topic.sh install-rules
#
# tag, list, order, setup, and --in-home only read and write files; they do not
# need the board service, so they keep working when it is down. Every other
# subcommand talks to the board service over its Unix socket and, except for
# status and stop, starts the service first when it is not running. Those run
# only in the main home and need node 22 or newer. Repeating any of them
# unchanged is safe.
#
# create makes a topic that is confirmed at once and last in its queue:
# normal unless --queue names another. A live topic with the same name and
# goal is the same topic, so a repeat prints its id and leaves it where it is.
#
# open prints the board's URL. status and stop never start the service, but
# the main home's next session start does (bin/fm-topic-session-start.sh).
#
# summary stores a one-to-three sentence milestone summary read from stdin (at
# most 600 characters) and prints the line to start the chat reminder with:
# "<topic name>：", "未分類：" when the task has no topic, or "議題不明（<task-id>）："
# when the task's home could not be read. which prints the same line without
# storing anything. --home names the secondmate home the task lives in.
#
# split makes a new confirmed topic out of part of <topic-id>, right after it
# in the same queue, and retags the named tasks to it. Every task must be
# tagged with <topic-id> now; a task of a local secondmate is written as
# <secondmate-id>/<task-id>, and a remote secondmate's task cannot be moved this
# way. The tasks are checked before anything is written. If tagging stops
# halfway, run the same command again: the topic is reused and the rest moved.
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
# tag    Appends "<topic-id> <UTC time>" to this home's data/<task-id>/topic.
#        The last line is the task's current topic. In the main home the topic
#        must be on the board and not archived (merged ids are followed), and
#        --in-home tag runs the same check in the main home before it writes
#        in the secondmate's. A secondmate home cannot read the topic file, so
#        its own tag (and one run through fm-on.sh) checks only the id format;
#        the board lists a task tagged with an id it does not know as 標記的議題不存在.
#        Without jq the check is skipped with a warning.
# list   Prints id, status, queue, position, and name of every topic. --all adds
#        archived topics. Main home only.
# order  Prints which queued backlog items to dispatch, hold, and release, in
#        the board's queue order, and under 等你驗證 the hands-on items the
#        captain says are done. Read-only: it never changes the backlog, and
#        when the topic file or the backlog cannot be read it says so and lets
#        dispatch proceed. An item under 該解除 is also listed under 可派, marked
#        as still held, so its place in the order is visible before the hold is
#        lifted. Items held by anything else (a captain hold, another hold, an
#        unresolved blocker) are in no section: upstream's own gates decide
#        those. Without a usable topic file, items the board held earlier are
#        still listed under 停著 so that a leftover hold is not forgotten.
# setup  Creates this home's config/fleet-ledger flag. Safe to repeat.
#
# install-rules writes the board's rules into this home's data/captain.md and
# data/captain-shared.md, each as one block between "<!-- topic-board:begin"
# and "<!-- topic-board:end -->" lines. An existing block is replaced whole;
# nothing outside the block is changed, and each file is backed up to
# state/topic-board/rules-backup/ before it is written. Main home only; it
# needs neither the board service nor node. status reports whether each block
# matches the templates in topic-board/rules/.
#
# --in-home runs tag, answers, or setup inside a LOCAL registered secondmate
# home. answers forwards stdin to that home's
# "fm-captain-hold.sh answers --source topic-board" and returns its output and
# exit code unchanged.
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
RULES_DIR="$FM_ROOT/topic-board/rules"
RULES_BEGIN='<!-- topic-board:begin'
RULES_END='<!-- topic-board:end -->'
DEFAULT_PORT=47819
EXIT_UNAVAILABLE=69
TOPICS_FILE="$DATA/topics.json"
ARCHIVE_FILE="$DATA/topics-archive.json"
OWN_HOLD_PREFIX='topic-board：'
TODO_MARKER='動手：'

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-topic-lib.sh
. "$SCRIPT_DIR/fm-topic-lib.sh"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

usage_error() {
  printf '%s\n' "fm-topic.sh: $*（fm-topic.sh --help 看用法）" >&2
  exit 2
}

in_secondmate_home() {
  fm_root_is_secondmate_home "$FM_HOME"
}

require_main_home() {
  if in_secondmate_home; then
    tb_die 1 "議題檔只在主 home；這裡是 secondmate home，不能跑 $1。"
  fi
}

require_jq() {
  command -v jq >/dev/null 2>&1 ||
    tb_die 1 "$1 需要 jq，但找不到。安裝：$(tb_jq_install_hint)"
}

# The live (unarchived) id that <topic-id> resolves to through the merged
# table, or nothing when it resolves to no live topic.
resolve_live_topic() {
  [ -f "$TOPICS_FILE" ] || return 0
  jq -r --arg id "$1" '
    . as $doc
    | {id: $id, hops: 0}
    | until(.hops > 64 or (($doc.merged // {})[.id] == null);
            {id: ($doc.merged[.id]), hops: (.hops + 1)})
    | .id as $final
    | if $doc.topics[$final] != null then $final else empty end
  ' "$TOPICS_FILE"
}

list_live_topics() {
  [ -f "$TOPICS_FILE" ] || return 0
  jq -r '.topics | to_entries[] | "  \(.key)\t\(.value.name)"' "$TOPICS_FILE"
}

# Decide which topic id a main-home tag should record for <topic-id>.
main_home_topic_for_tag() {
  local wanted=$1 resolved
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "警告：找不到 jq，沒有檢查 $wanted 是不是看板上的議題。安裝：$(tb_jq_install_hint)" >&2
    printf '%s\n' "$wanted"
    return 0
  fi
  resolved=$(resolve_live_topic "$wanted") ||
    tb_die 1 "讀不懂 ${TOPICS_FILE}，沒有寫入標記。"
  if [ -z "$resolved" ]; then
    {
      printf '%s\n' "$wanted 不是看板上還開著的議題，沒有寫入標記。可用的議題："
      list_live_topics || true
    } >&2
    exit 1
  fi
  printf '%s\n' "$resolved"
}

current_topic_of() {
  local file="$DATA/$1/topic" last
  [ -f "$file" ] || return 1
  last=$(tail -n 1 "$file")
  [ -n "$last" ] || return 1
  printf '%s\n' "${last%% *}"
}

cmd_tag() {
  local task topic source
  case "$#" in
    2)
      task=$1
      topic=$2
      tb_valid_id "$task" || usage_error "task id 格式不對：$task"
      tb_valid_id "$topic" || usage_error "議題 id 格式不對：$topic"
      if ! in_secondmate_home; then
        topic=$(main_home_topic_for_tag "$topic")
      fi
      ;;
    3)
      [ "$2" = --from ] || usage_error "tag 的用法是 <task-id> <議題 id> 或 <新 id> --from <舊 id>"
      task=$1
      source=$3
      tb_valid_id "$task" || usage_error "task id 格式不對：$task"
      tb_valid_id "$source" || usage_error "task id 格式不對：$source"
      topic=$(current_topic_of "$source") ||
        tb_die 1 "$source 沒有議題標記，沒有東西可以沿用。"
      ;;
    *) usage_error "tag 的用法是 <task-id> <議題 id> 或 <新 id> --from <舊 id>" ;;
  esac
  if [ "$(current_topic_of "$task" || true)" != "$topic" ]; then
    mkdir -p "$DATA/$task"
    printf '%s %s\n' "$topic" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$DATA/$task/topic"
  fi
  printf '%s\n' "ok $task 已標記為 $topic"
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
  require_main_home list
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

cmd_setup() {
  [ "$#" -eq 0 ] || usage_error "setup 不收參數"
  if [ -e "$CONFIG/fleet-ledger" ]; then
    printf '%s\n' "ok setup 帳本本來就開著"
    return 0
  fi
  mkdir -p "$CONFIG"
  : > "$CONFIG/fleet-ledger"
  printf '%s\n' "ok setup 帳本已開"
}

# Print the snapshot JSON, or return non-zero when it cannot be produced.
order_snapshot() {
  local -a runner=()
  if command -v timeout >/dev/null 2>&1; then
    runner=(timeout 30)
  fi
  FM_HOME="$FM_HOME" FM_SNAPSHOT_SECONDMATES=1 FM_SNAPSHOT_BUDGET=1 FM_CREW_STATE_NO_FORGE=1 \
    "${runner[@]+"${runner[@]}"}" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null
}

# One "<task-id>\t<last tagged topic id>" line per tagged task in this home.
order_tags() {
  local file task last
  for file in "$DATA"/*/topic; do
    [ -f "$file" ] || continue
    task=${file%/topic}
    task=${task##*/}
    last=$(tail -n 1 "$file")
    [ -n "$last" ] || continue
    printf '%s\t%s\n' "$task" "${last%% *}"
  done
}

cmd_order() {
  local snapshot tags topics=/dev/null archive=/dev/null note=''
  [ "$#" -eq 0 ] || usage_error "order 不收參數"
  require_jq order
  if in_secondmate_home; then
    note='這裡是 secondmate home，沒有議題檔；照 backlog 原本的順序列出。'
  elif [ ! -f "$TOPICS_FILE" ]; then
    note='還沒有議題檔；照 backlog 原本的順序列出。'
  elif ! jq -e '(.queues | type == "object") and (.topics | type == "object")' "$TOPICS_FILE" >/dev/null 2>&1; then
    note="讀不懂 ${TOPICS_FILE}；照 backlog 原本的順序列出。"
  else
    topics=$TOPICS_FILE
    if [ -f "$ARCHIVE_FILE" ] && jq -e '.topics | type == "object"' "$ARCHIVE_FILE" >/dev/null 2>&1; then
      archive=$ARCHIVE_FILE
    fi
  fi
  if ! snapshot=$(order_snapshot) || [ -z "$snapshot" ]; then
    printf '%s\n' "讀不到 backlog，照平常的方式派工。"
    return 0
  fi
  tags=$(order_tags)
  printf '%s' "$snapshot" | jq -r --arg note "$note" --arg tags "$tags" --arg own "$OWN_HOLD_PREFIX" --arg marker "$TODO_MARKER" \
    --slurpfile live "$topics" --slurpfile gone "$archive" '
    ($live[0] // null) as $doc
    | ($gone[0].topics // {}) as $archived
    | ($tags | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]})
       | from_entries) as $tag
    | def resolve: {id: ., hops: 0}
        | until(.hops > 64 or ((($doc.merged // {})[.id]) == null);
                {id: ($doc.merged[.id]), hops: (.hops + 1)})
        | .id;
      def place($topic):
        if $doc == null or $topic == null then {queue: "none"}
        elif ($archived[$topic] != null) then {queue: "archived", name: $archived[$topic].name}
        else ( [ ("high", "normal", "later") as $q
                 | ($doc.queues[$q] // []) | index($topic) as $at
                 | select($at != null) | {queue: $q, at: $at, name: $doc.topics[$topic].name} ][0]
               // {queue: "none"} )
        end;
      def queue_name: {high: "高", normal: "一般", later: "待辦", archived: "已封存", none: "-"}[.];
      [ .backlog.records | to_entries[]
        | select(.value.structured == true and .value.state == "queued")
        | .key as $index | .value as $r
        | ($tag[$r.id] | if . == null then null else resolve end) as $topic
        | place($topic) as $p
        | {id: $r.id, index: $index, topic: $topic, queue: $p.queue, at: ($p.at // 0),
           name: ($p.name // "（未分類）"),
           decision: ($r.kind == "captain"),
           claimed: ((($r.hold_reason // "") | startswith($marker))
                     and ((($doc.todos // {}) | objects | .[$r.id] | objects | .state) == "claimed")),
           own_hold: (($r.hold_reason // "") | startswith($own)),
           other_hold: ($r.hold_reason != null and ((($r.hold_reason // "") | startswith($own)) | not)),
           blocked: (($r.unresolved_blocker_ids // []) | length > 0),
           parked: ($p.queue == "later" or $p.queue == "archived")} ] as $items
    | def line: "  \(.id)\t\(.name)\t\(.queue | queue_name)";
      def rank: {high: 0, normal: 1, none: 2}[.queue];
      ($items | map(select((.parked | not) and (.other_hold | not) and (.blocked | not)
                           and ($doc != null or (.own_hold | not))))
       | sort_by([rank, .at, .index])) as $ready
    | ($items | map(select(.parked and (.own_hold | not) and (.other_hold | not)))) as $to_hold
    | ($items | map(select($doc != null and .own_hold and (.parked | not)))) as $to_release
    | ($items | map(select(.own_hold and (.parked or $doc == null)))) as $parked
    | (if $note != "" then $note else empty end),
      "可派：",
      ($ready[] | line
        + (if .own_hold then "\t← 還被看板的 hold 擋著，先照「該解除」解除" else "" end)
        + (if .decision then "\t← 決定事項，使用者已經回答；沒有工作要派，照回答處理後關掉" else "" end)),
      "該 hold：",
      ($to_hold[] | line + "\t→ bin/fm-tasks-axi.sh hold \(.id) --reason \"\($own)議題 \(.topic) 在\(if .queue == "archived" then "封存" else "待辦" end)\""),
      "該解除：",
      ($to_release[] | line + "\t→ bin/fm-tasks-axi.sh unhold \(.id)"),
      "停著：",
      ($parked[] | line),
      ($items | map(select(.claimed)) as $claimed
       | if ($claimed | length) == 0 then empty
         else "等你驗證：",
              ($claimed[] | line + "\t← 使用者說做完了；驗證後跑 bin/fm-topic.sh todo done \(.id)，沒成功就跑 bin/fm-topic.sh todo failed \(.id) --reason <一行>")
         end)
  ' || {
    printf '%s\n' "讀不到 backlog，照平常的方式派工。"
    return 0
  }
}

# The data directory holding <task-spec>'s tag file: this home's for "<task>",
# a local secondmate's for "<secondmate-id>/<task>". Prints nothing and returns
# 1, after explaining, when the spec is malformed or the home is remote.
split_task_data() {
  local spec=$1 home
  case "$spec" in
    */*)
      if ! tb_valid_id "${spec%%/*}" || ! tb_valid_id "${spec#*/}"; then
        printf '%s\n' "${spec}：task 要寫成 <task-id> 或 <secondmate-id>/<task-id>。" >&2
        return 1
      fi
      home=$(tb_local_secondmate_home "$DATA/secondmates.md" "${spec%%/*}") || {
        printf '%s\n' "${spec}：split 只能搬主 home 和已註冊的本機 secondmate 的 task；遠端 secondmate 的請它自己跑 tag。" >&2
        return 1
      }
      printf '%s\n' "$home/data"
      ;;
    *)
      tb_valid_id "$spec" || {
        printf '%s\n' "${spec}：task id 格式不對。" >&2
        return 1
      }
      printf '%s\n' "$DATA"
      ;;
  esac
}

# Why <task-spec> cannot move from topic <source> to <new>, or nothing when it can.
split_task_problem() {
  local spec=$1 source=$2 new=$3 data file current
  data=$(split_task_data "$spec" 2>&1) || {
    printf '%s\n' "$data"
    return 0
  }
  file="$data/${spec#*/}/topic"
  [ -s "$file" ] || {
    printf '%s\n' "${spec}：沒有議題標記，不在 $source 裡。"
    return 0
  }
  current=$(tail -n 1 "$file")
  current=${current%% *}
  [ "$current" = "$new" ] && return 0
  [ "$(resolve_live_topic "$current")" = "$source" ] ||
    printf '%s\n' "${spec}：現在標的是 ${current}，不在 $source 裡。"
}

# The topic id in the board's answer to a split: the second word of its first line.
split_new_id() {
  printf '%s\n' "$1" | awk 'NR == 1 { print $2 }'
}

# split <source> <name> --goal <line> [--id <id>] [<task-spec>...]: split a new
# topic off <source> and retag the named tasks to it. The tasks are checked
# before anything is written. Tagging happens after the topic exists, so a run
# that stops halfway is finished by running the same command again.
cmd_split() {
  local goal="" id="" reason="" has_reason=0 plan made new source spec problem problems="" failed=0
  local -a words=() request=() tasks=()
  require_main_home split
  require_jq split
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --goal | --id | --reason)
        [ "$#" -ge 2 ] || usage_error "$1 後面要有值"
        case "$1" in
          --goal) goal=$2 ;;
          --id) id=$2 ;;
          --reason)
            reason=$2
            has_reason=1
            ;;
        esac
        shift 2
        ;;
      --*) usage_error "split 不認得 $1" ;;
      *)
        words+=("$1")
        shift
        ;;
    esac
  done
  if [ "${#words[@]}" -lt 2 ] || [ -z "$goal" ]; then
    usage_error "split 的用法是 <來源議題> <新名稱> --goal <一行> [--id <id>] [--reason <一行>] [<task>|<secondmate-id>/<task>]…"
  fi
  request=(split "${words[0]}" "${words[1]}" --goal "$goal")
  [ -z "$id" ] || request+=(--id "$id")
  # An empty reason is passed on so the board refuses it, the same as for merge.
  [ "$has_reason" -eq 0 ] || request+=(--reason "$reason")
  [ "${#words[@]}" -le 2 ] || tasks=("${words[@]:2}")
  # Each step below runs this script again as its own process. Called as a
  # function behind "||", a step would run with errexit off and could carry on
  # after a failure.
  plan=$("$SELF" split-topic "${request[@]}" --dry) || exit $?
  source=$(resolve_live_topic "${words[0]}")
  for spec in ${tasks[@]+"${tasks[@]}"}; do
    problem=$(split_task_problem "$spec" "$source" "$(split_new_id "$plan")")
    [ -z "$problem" ] || problems+="$problem"$'\n'
  done
  if [ -n "$problems" ]; then
    printf '%s' "$problems" >&2
    tb_die 1 "有 task 不能搬，什麼都沒有改。"
  fi
  # The id comes from the split that was really made: another writer may have
  # taken the planned id since the check.
  made=$("$SELF" split-topic "${request[@]}") || exit $?
  printf '%s\n' "$made"
  new=$(split_new_id "$made")
  tb_valid_id "$new" || tb_die 1 "看不懂看板回的議題 id，沒有搬任何 task：$made"
  for spec in ${tasks[@]+"${tasks[@]}"}; do
    case "$spec" in
      */*) "$SELF" --in-home "${spec%%/*}" tag "${spec#*/}" "$new" || failed=1 ;;
      *) "$SELF" tag "$spec" "$new" || failed=1 ;;
    esac
  done
  [ "$failed" -eq 0 ] || tb_die 1 "有 task 沒有標成功；修好之後原樣再跑一次同一個指令就會接著做完。"
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
  topic=$(main_home_topic_for_tag "$topic")
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
  "$SELF" tag "${words[0]}" "$topic" >/dev/null ||
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
  require_main_home todo
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

cmd_in_home() {
  local id home topic
  [ "$#" -ge 2 ] || usage_error "--in-home 的用法是 --in-home <secondmate-id> <tag|answers|setup> …"
  id=$1
  shift
  case "$1" in
    tag | answers | setup) ;;
    *) usage_error "--in-home 只支援 tag、answers、setup，不支援 $1" ;;
  esac
  home=$(tb_local_secondmate_home "$DATA/secondmates.md" "$id") || exit 1
  if [ "$1" = tag ] && [ "$#" -eq 3 ]; then
    tb_valid_id "$2" || usage_error "task id 格式不對：$2"
    tb_valid_id "$3" || usage_error "議題 id 格式不對：$3"
    topic=$(main_home_topic_for_tag "$3")
    set -- tag "$2" "$topic"
  fi
  if [ "$1" = answers ]; then
    [ "$#" -eq 1 ] || usage_error "answers 不收參數，答案一行走 stdin"
    tb_exec_in_home "$home" "$SCRIPT_DIR/fm-captain-hold.sh" answers --source topic-board
  fi
  tb_exec_in_home "$home" "$SCRIPT_DIR/fm-topic.sh" "$@"
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

# Where the rules block sits in <file>: prints "none", "ok <begin-line>
# <end-line>", or "broken <what is wrong>" when the two markers do not form
# exactly one block. A marker line may be indented or carry text after the
# marker, so a block that an editor or a curation pass reshaped is still found.
rules_block() {
  awk -v begin="$RULES_BEGIN" -v end="$RULES_END" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    index(line, begin) == 1 { begins = begins " " NR; b++ }
    index(line, end) == 1 { ends = ends " " NR; e++ }
    END {
      if (b == 0 && e == 0) print "none"
      else if (b == 1 && e == 1 && begins + 0 < ends + 0) print "ok" begins ends
      else print "broken 開頭標記在第" (b ? begins : " -") " 行，結尾標記在第" (e ? ends : " -") " 行"
    }
  ' "$1"
}

# The "vN" on a block's first line, for people; the content decides what is current.
rules_version() {
  sed -n '1s/^.*topic-board:begin \(v[0-9]*\).*$/\1/p'
}

# One file's rules state for status: 未裝, 和範本相同（vN）, or 和範本不同（vN）.
rules_state() {  # <file> <template>
  local file=$1 template=$2 block first last installed
  [ -f "$file" ] || { printf '未裝'; return 0; }
  block=$(rules_block "$file")
  case "$block" in
    none) printf '未裝' ;;
    ok\ *)
      read -r _ first last <<< "$block"
      installed=$(sed -n "${first},${last}p" "$file")
      if [ "$installed" = "$(cat "$template")" ]; then
        printf '和範本相同（%s）' "$(printf '%s\n' "$installed" | rules_version)"
      else
        printf '和範本不同（%s）' "$(printf '%s\n' "$installed" | rules_version)"
      fi
      ;;
    *) printf '標記不完整' ;;
  esac
}

print_rules_status() {
  printf '規則：captain.md %s；captain-shared.md %s\n' \
    "$(rules_state "$DATA/captain.md" "$RULES_DIR/captain.block.md.tmpl")" \
    "$(rules_state "$DATA/captain-shared.md" "$RULES_DIR/captain-shared.block.md.tmpl")"
}

# Print what <file> should contain once <template> is installed, or return 1
# after explaining why the file is left alone.
rules_new_content() {  # <file> <template> [header-template]
  local file=$1 template=$2 header=${3:-} block first last
  if [ ! -f "$file" ]; then
    [ -z "$header" ] || cat "$header"
    cat "$template"
    return 0
  fi
  block=$(rules_block "$file")
  case "$block" in
    none)
      cat "$file"
      [ -z "$(tail -c 1 "$file")" ] || printf '\n'
      [ ! -s "$file" ] || printf '\n'
      cat "$template"
      ;;
    ok\ *)
      read -r _ first last <<< "$block"
      head -n "$((first - 1))" "$file"
      cat "$template"
      tail -n "+$((last + 1))" "$file"
      ;;
    *)
      printf '%s\n' "${file##*/}：標記不成對（${block#broken }），沒有動這個檔。請手動整理成一對標記，或把它們都刪掉。" >&2
      return 1
      ;;
  esac
}

# Upstream's own check of a shared preference file's header: prints the first
# required phrase that is missing and returns 1, or prints nothing and returns
# 0. Run in a subshell so the library it comes from defines nothing here.
shared_header_gap() {
  (
    # shellcheck source=bin/fm-config-inherit-lib.sh
    . "$SCRIPT_DIR/fm-config-inherit-lib.sh" >/dev/null 2>&1 && shared_captain_header_valid "$1"
  )
}

# Install one template into one preference file; prints what happened.
install_rules_file() {  # <file> <template> [header-template]
  local file=$1 template=$2 header=${3:-} name=${1##*/} gap fresh before after backup
  if [ -n "$header" ] && [ -f "$file" ]; then
    gap=$(shared_header_gap "$file") || {
      printf '%s\n' "${name}：檔頭不合上游的要求（少了「${gap}」），沒有動這個檔。" >&2
      return 1
    }
  fi
  fresh="$STATE/topic-board/rules.new.$$"
  rules_new_content "$file" "$template" "$header" > "$fresh" || {
    rm -f "$fresh"
    return 1
  }
  after=$(rules_version < "$template")
  if [ ! -f "$file" ]; then
    mkdir -p "$DATA"
    mv "$fresh" "$file"
    printf '%s\n' "${name}：新增（${after}）"
  elif cmp -s "$fresh" "$file"; then
    rm -f "$fresh"
    printf '%s\n' "${name}：已是最新（${after}）"
  else
    before=$(rules_state "$file" "$template")
    backup="$STATE/topic-board/rules-backup/$name.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$file" "$backup"
    mv "$fresh" "$file"
    case "$before" in
      未裝) printf '%s\n' "${name}：新增（${after}），原檔備份在 $backup" ;;
      *) printf '%s\n' "${name}：已更新（$before → ${after}），原檔備份在 $backup" ;;
    esac
  fi
}

list_secondmate_ids() {
  local reg="$DATA/secondmates.md" line
  [ -f "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    printf '%s ' "$SECONDMATE_REGISTRY_ID"
  done < "$reg"
}

cmd_install_rules() {
  local failed=0 secondmates
  [ "$#" -eq 0 ] || usage_error "install-rules 不收參數"
  if in_secondmate_home; then
    tb_die 1 "install-rules 只能在主 home 跑。secondmate home 的共用偏好檔是主 home 傳過來的唯讀複本，改了會被當成漂移。什麼都沒有寫。"
  fi
  [ -d "$FM_HOME" ] || tb_die 1 "找不到 home：${FM_HOME}。什麼都沒有寫。"
  [ -f "$RULES_DIR/captain.block.md.tmpl" ] || tb_die 1 "找不到規則範本（${RULES_DIR}）。什麼都沒有寫。"
  mkdir -p "$STATE/topic-board/rules-backup"
  chmod 700 "$STATE/topic-board" "$STATE/topic-board/rules-backup"
  install_rules_file "$DATA/captain.md" "$RULES_DIR/captain.block.md.tmpl" || failed=1
  install_rules_file "$DATA/captain-shared.md" "$RULES_DIR/captain-shared.block.md.tmpl" \
    "$RULES_DIR/captain-shared.header.md.tmpl" || failed=1
  secondmates=$(list_secondmate_ids)
  printf '%s\n' "已註冊的 secondmate：${secondmates:-（沒有）}"
  printf '%s\n' "提醒：共用段會叫每個 secondmate 跑 fm-topic.sh；還沒換到 fork 的 home 沒有這支指令。"
  printf '%s\n' "生效時間：主 first mate 是下一次 session 開始或下一次壓縮後；secondmate 是主 home 下一次 bootstrap 傳播共用檔之後、它下次啟動時。"
  "$SCRIPT_DIR/fm-startup-memory-budget.sh" report 2>&1 || printf '%s\n' "（讀不到啟動記憶的預算，沒有檢查用量。）"
  return "$failed"
}

# Hand a socket subcommand to the node client, after the checks that must not
# need node themselves.
cmd_service() {
  local sub=$1 port commit major
  require_main_home "$sub"
  if ! command -v node >/dev/null 2>&1; then
    if [ "$sub" = status ]; then
      status_without_node
      print_rules_status
      return 0
    fi
    service_unavailable "沒有 node" "安裝：brew install node  # or the platform's package manager"
  fi
  major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')
  case "$major" in '' | *[!0-9]*) major=0 ;; esac
  [ "$major" -ge 22 ] || service_unavailable "node 版本低於 22" "請升級到 22 以上"
  if [ ! -f "$BOARD_DIST/board-client.js" ] || [ ! -f "$BOARD_DIST/board-server.js" ]; then
    service_unavailable "編譯結果不見了（${BOARD_DIST}）" "在主 home 跑 /updatefirstmate，或確認 checkout 完整"
  fi
  port=$(configured_port)
  commit=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')
  if [ "$sub" = status ]; then
    node "$BOARD_DIST/board-client.js" --home "$FM_HOME" --root "$FM_ROOT" --commit "$commit" \
      --port "$port" --state "$STATE" --data "$DATA" -- "$@"
    print_rules_status
    return 0
  fi
  exec node "$BOARD_DIST/board-client.js" --home "$FM_HOME" --root "$FM_ROOT" --commit "$commit" \
    --port "$port" --state "$STATE" --data "$DATA" -- "$@"
}

main() {
  [ "$#" -gt 0 ] || usage_error "少了子命令"
  local sub=$1
  shift
  case "$sub" in
    -h | --help)
      usage
      ;;
    --in-home) cmd_in_home "$@" ;;
    tag) cmd_tag "$@" ;;
    split) cmd_split "$@" ;;
    # Internal: forget a hands-on item's mark after its text was rewritten.
    todo-clear) cmd_service "$sub" "$@" ;;
    # Internal: the board's own split operation, without the task handling.
    split-topic) cmd_service "$@" ;;
    todo) cmd_todo "$@" ;;
    list) cmd_list "$@" ;;
    order) cmd_order "$@" ;;
    setup) cmd_setup "$@" ;;
    install-rules) cmd_install_rules "$@" ;;
    # The board confirms every topic it makes; rules from before that still name these.
    propose | confirm) usage_error "沒有 ${sub} 了：議題一建立就已確認。新議題用 create <名稱> --goal <一行>" ;;
    create | merge | close-propose | move | rename | goal | archive | reopen | \
      summary | retract | which | find | open | status | stop | restart | reset-token)
      cmd_service "$sub" "$@"
      ;;
    *) usage_error "不認得的子命令：$sub" ;;
  esac
}

main "$@"
