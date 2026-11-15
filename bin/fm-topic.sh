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
#   fm-topic.sh propose <name> --goal <one line> [--id <id>] [--queue high|normal|later]
#   fm-topic.sh confirm <topic-id> [--queue <queue>]
#   fm-topic.sh merge <old-topic-id> <new-topic-id>
#   fm-topic.sh close-propose <topic-id> --reason <text>
#   fm-topic.sh move <topic-id> <queue> [--before <topic-id> | --first]
#   fm-topic.sh rename <topic-id> <name>
#   fm-topic.sh goal <topic-id> <one line>
#   fm-topic.sh archive <topic-id>
#   fm-topic.sh reopen <topic-id> [--queue <queue>]
#   fm-topic.sh open | status | stop | restart | reset-token
#
# tag, list, order, setup, and --in-home only read and write files; they do not
# need the board service, so they keep working when it is down. Every other
# subcommand talks to the board service over its Unix socket and, except for
# status and stop, starts the service first when it is not running. Those run
# only in the main home and need node 22 or newer. Repeating any of them
# unchanged is safe.
#
# open prints the board's URL. status and stop never start the service.
#
# tag    Appends "<topic-id> <UTC time>" to this home's data/<task-id>/topic.
#        The last line is the task's current topic. In the main home the topic
#        must be confirmed and not archived (merged ids are followed); a
#        secondmate home cannot read the topic file, so only the id format is
#        checked there. Without jq the confirmed check is skipped with a warning.
# list   Prints id, status, queue, position, and name of every topic. --all adds
#        archived topics. Main home only.
# order  Prints which queued backlog items to dispatch, hold, and release, in
#        the board's queue order. Read-only: it never changes the backlog, and
#        when the topic file or the backlog cannot be read it says so and lets
#        dispatch proceed.
# setup  Creates this home's config/fleet-ledger flag. Safe to repeat.
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
OWN_HOLD_PREFIX='topic-board：'

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

# The usable (confirmed, unarchived) id that <topic-id> resolves to through the
# merged table, or nothing when it resolves to no usable topic.
resolve_confirmed_topic() {
  [ -f "$TOPICS_FILE" ] || return 0
  jq -r --arg id "$1" '
    . as $doc
    | {id: $id, hops: 0}
    | until(.hops > 64 or (($doc.merged // {})[.id] == null);
            {id: ($doc.merged[.id]), hops: (.hops + 1)})
    | .id as $final
    | if ($doc.topics[$final].status // "") == "confirmed" then $final else empty end
  ' "$TOPICS_FILE"
}

list_confirmed_topics() {
  [ -f "$TOPICS_FILE" ] || return 0
  jq -r '.topics | to_entries[] | select(.value.status == "confirmed")
         | "  \(.key)\t\(.value.name)"' "$TOPICS_FILE"
}

# Decide which topic id a main-home tag should record for <topic-id>.
main_home_topic_for_tag() {
  local wanted=$1 resolved
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "警告：找不到 jq，沒有檢查 $wanted 是不是已確認的議題。安裝：$(tb_jq_install_hint)" >&2
    printf '%s\n' "$wanted"
    return 0
  fi
  resolved=$(resolve_confirmed_topic "$wanted") ||
    tb_die 1 "讀不懂 $TOPICS_FILE，沒有寫入標記。"
  if [ -z "$resolved" ]; then
    {
      printf '%s\n' "$wanted 不是已確認、未封存的議題，沒有寫入標記。可用的議題："
      list_confirmed_topics || true
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
    | [ $doc.topics | to_entries[] | select(.value.status == "proposed")
        | {id: .key, status: "proposed", queue: null, position: null, name: .value.name} ] as $proposed
    | [ ($gone[0].topics // {}) | to_entries[]
        | {id: .key, status: "archived", queue: null, position: null, name: .value.name} ] as $archived
    | ($queued + $proposed + $archived) as $rows
    | if $json == 1 then $rows
      elif ($rows | length) == 0 then "還沒有議題。"
      else $rows[] | "\(.id)\t\(.status)\t\(.queue // "-")\t\(.position // "-")\t\(.name)"
      end
  ' || tb_die 1 "讀不懂 $TOPICS_FILE 或 $ARCHIVE_FILE。"
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
    note="讀不懂 $TOPICS_FILE；照 backlog 原本的順序列出。"
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
  printf '%s' "$snapshot" | jq -r --arg note "$note" --arg tags "$tags" --arg own "$OWN_HOLD_PREFIX" \
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
    | ($items | map(select(.own_hold and .parked))) as $parked
    | (if $note != "" then $note else empty end),
      "可派：",
      ($ready[] | line),
      "該 hold：",
      ($to_hold[] | line + "\t→ bin/fm-tasks-axi.sh hold \(.id) --reason \"\($own)議題 \(.topic) 在\(if .queue == "archived" then "封存" else "待辦" end)\""),
      "該解除：",
      ($to_release[] | line + "\t→ bin/fm-tasks-axi.sh unhold \(.id)"),
      "停著：",
      ($parked[] | line)
  ' || {
    printf '%s\n' "讀不到 backlog，照平常的方式派工。"
    return 0
  }
}

cmd_in_home() {
  local id home
  [ "$#" -ge 2 ] || usage_error "--in-home 的用法是 --in-home <secondmate-id> <tag|answers|setup> …"
  id=$1
  shift
  case "$1" in
    tag | answers | setup) ;;
    *) usage_error "--in-home 只支援 tag、answers、setup，不支援 $1" ;;
  esac
  home=$(tb_local_secondmate_home "$DATA/secondmates.md" "$id") || exit 1
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

# Hand a socket subcommand to the node client, after the checks that must not
# need node themselves.
cmd_service() {
  local sub=$1 port commit major
  require_main_home "$sub"
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
    service_unavailable "編譯結果不見了（$BOARD_DIST）" "在主 home 跑 /updatefirstmate，或確認 checkout 完整"
  fi
  port=$(configured_port)
  commit=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')
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
    list) cmd_list "$@" ;;
    order) cmd_order "$@" ;;
    setup) cmd_setup "$@" ;;
    propose | confirm | merge | close-propose | move | rename | goal | archive | reopen | \
      open | status | stop | restart | reset-token)
      cmd_service "$sub" "$@"
      ;;
    *) usage_error "不認得的子命令：$sub" ;;
  esac
}

main "$@"
