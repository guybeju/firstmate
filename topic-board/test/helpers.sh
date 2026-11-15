#!/usr/bin/env bash
# Shared fixtures for the topic-board tests. Sourced after tests/lib.sh.
# shellcheck disable=SC2034 # the path globals are read by the sourcing tests.

TOPIC="$ROOT/bin/fm-topic.sh"
BOARD_READ="$ROOT/bin/fm-topic-board-read.sh"

# tb_make_home <name>: create an empty main home under TMP_ROOT and print it.
tb_make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

# tb_make_secondmate_home <name> <id>: like tb_make_home plus the marker file
# upstream uses to recognize a secondmate home.
tb_make_secondmate_home() {
  local home
  home=$(tb_make_home "$1")
  printf '%s\n' "$2" > "$home/.fm-secondmate-home"
  printf '%s\n' "$home"
}

# tb_write_topics <home>: two confirmed topics, one parked, one proposed, one
# merged alias, and one archived topic.
tb_write_topics() {
  local home=$1
  cat > "$home/data/topics.json" <<'JSON'
{
  "v": 1,
  "next_seq": 3,
  "queues": { "high": ["billing"], "normal": ["t2"], "later": ["parked"] },
  "topics": {
    "billing": { "name": "帳務重構", "goal": "搬到新服務", "status": "confirmed" },
    "t2": { "name": "登入頁", "goal": "改版", "status": "confirmed" },
    "parked": { "name": "之後再說", "goal": "先放著", "status": "confirmed" },
    "idea": { "name": "新點子", "goal": "還沒確認", "status": "proposed" }
  },
  "merged": { "old-billing": "billing" }
}
JSON
  cat > "$home/data/topics-archive.json" <<'JSON'
{ "v": 1, "topics": { "gone": { "name": "已結束", "goal": "做完了", "status": "confirmed", "archived_at": "2026-11-01T00:00:00Z" } } }
JSON
}

# tb_run <home> <command...>: run a fork script against <home> with this
# checkout as the code root.
tb_run() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@"
}

# tb_code <home> <command...>: run like tb_run, discard output, print the exit code.
tb_code() {
  local rc=0
  tb_run "$@" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# tb_write_registry <main-home> <local-secondmate-home>: register one local
# secondmate (sm1) and one remote secondmate (far1).
tb_write_registry() {
  cat > "$1/data/secondmates.md" <<EOF
# Secondmates
- sm1 - Local helper (home: $2; scope: sample work; projects: alpha; added 2026-11-01)
- far1 - Remote helper (host: farbox; root: /srv/fm; home: /srv/fm-home; scope: remote work; projects: beta; added 2026-11-01)
EOF
}
