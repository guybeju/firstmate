#!/usr/bin/env bash
# fm-dispatch-plan.sh - firstmate's dispatch plan from the topic board's queues.
#
# Usage:
#   fm-dispatch-plan.sh order
#
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
#
# It reads the board's data/topics.json and data/topics-archive.json, the
# home's data/<task-id>/topic tag files, and the backlog through
# fm-fleet-snapshot.sh. It needs jq. In a secondmate home, which has no topic
# file, it lists the backlog in its own order.
#
# Exit codes: 0 success (including the fall-open answers), 1 refused, 2 usage
# error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TOPICS_FILE="$DATA/topics.json"
ARCHIVE_FILE="$DATA/topics-archive.json"
OWN_HOLD_PREFIX='topic-board：'
TODO_MARKER='動手：'

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/myshape-lib.sh
. "$SCRIPT_DIR/myshape-lib.sh"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

usage_error() {
  printf '%s\n' "fm-dispatch-plan.sh: $*（fm-dispatch-plan.sh --help 看用法）" >&2
  exit 2
}

in_secondmate_home() {
  fm_root_is_secondmate_home "$FM_HOME"
}

require_jq() {
  command -v jq >/dev/null 2>&1 ||
    tb_die 1 "$1 需要 jq，但找不到。安裝：$(tb_jq_install_hint)"
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
              ($claimed[] | line + "\t← 使用者說做完了；驗證後跑 bin/myshape.sh todo done \(.id)，沒成功就跑 bin/myshape.sh todo failed \(.id) --reason <一行>")
         end)
  ' || {
    printf '%s\n' "讀不到 backlog，照平常的方式派工。"
    return 0
  }
}

main() {
  [ "$#" -gt 0 ] || usage_error "少了子命令"
  local sub=$1
  shift
  case "$sub" in
    -h | --help) usage ;;
    order) cmd_order "$@" ;;
    *) usage_error "不認得的子命令：$sub" ;;
  esac
}

main "$@"
