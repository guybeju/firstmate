#!/usr/bin/env bash
# The board service's lifecycle as fm-topic.sh users see it: on-demand start,
# one instance per home, recovery from crashes and stale files, replacement on
# a code or port change, and the startup failures that exit 69.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot tb-s2)
trap 'tb_stop_boards; fm_test_cleanup' EXIT

test_starts_on_demand_and_stays_single() {
  local home out pid
  home=$(tb_make_service_home demand)
  out=$(tb_run "$home" "$TOPIC" status)
  assert_contains "$out" "沒在跑" "status must report a stopped board"
  assert_equals 0 "$(tb_board_count "$home")" "status must not start the board"
  tb_run "$home" "$TOPIC" stop >/dev/null || fail "stop on a stopped board must succeed"
  assert_equals 0 "$(tb_board_count "$home")" "stop must not start the board"

  tb_run "$home" "$TOPIC" propose "First" --goal "one" >/dev/null &
  tb_run "$home" "$TOPIC" propose "Second" --goal "two" >/dev/null &
  tb_run "$home" "$TOPIC" propose "Third" --goal "three" >/dev/null &
  wait
  assert_equals 1 "$(tb_board_count "$home")" "concurrent commands must leave exactly one board"
  assert_equals 3 "$(tb_run "$home" "$TOPIC" list --json | jq 'length')" "every concurrent proposal must be stored"
  pid=$(tb_board_pid "$home")
  tb_run "$home" "$TOPIC" propose "Fourth" --goal "four" >/dev/null
  assert_equals "$pid" "$(tb_board_pid "$home")" "a later command must reuse the running board"

  out=$(tb_run "$home" "$TOPIC" status)
  assert_contains "$out" "在跑" "status must report a running board"
  assert_contains "$out" "pid：$pid" "status must print the pid"
  assert_contains "$out" "events.jsonl：" "status must print the event file size"
  assert_equals "srw-------" "$(tb_mode "$home/state/topic-board/board.sock")" "the socket must be 0600"
  assert_equals "-rw-------" "$(tb_mode "$home/state/topic-board/token")" "the token must be 0600"
  assert_equals "drwx------" "$(tb_mode "$home/state/topic-board")" "the runtime directory must be 0700"
  out=$(tb_run "$home" "$TOPIC" open)
  assert_equals "http://127.0.0.1:$(cat "$home/config/topic-board-port")/#t=$(cat "$home/state/topic-board/token")" "$out" \
    "open must print the board URL with the token in the fragment"

  tb_run "$home" "$TOPIC" stop >/dev/null
  assert_equals 0 "$(tb_board_count "$home")" "stop must end the board"
  assert_absent "$home/state/topic-board/board.sock" "stop must remove the socket"
  pass "the board starts on demand, stays single, and stops on request"
}

test_recovers_from_a_crash() {
  local home pid
  home=$(tb_make_service_home crash)
  tb_run "$home" "$TOPIC" propose "Keep me" --goal "survive" --id keep >/dev/null
  tb_run "$home" "$TOPIC" confirm keep >/dev/null
  pid=$(tb_board_pid "$home")
  kill -KILL "$pid"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  assert_present "$home/state/topic-board/board.sock" "a killed board leaves its socket file behind"
  printf 'garbage' > "$home/data/topics.json.tmp-99999"
  printf '{"src":"board","half' >> "$home/data/topic-board/events.jsonl"
  jq -e '.topics.keep.status == "confirmed"' "$home/data/topics.json" >/dev/null ||
    fail "topics.json must be complete JSON after a kill -9"

  tb_run "$home" "$TOPIC" rename keep "Still here" >/dev/null || fail "the next command must restart a crashed board"
  assert_not_equals "$pid" "$(tb_board_pid "$home")" "a new board must have replaced the killed one"
  assert_absent "$home/data/topics.json.tmp-99999" "a stale temp file must be removed at startup"
  assert_equals 1 "$(wc -l < "$home/data/topic-board/events.jsonl" | tr -d ' ')" \
    "a half-written event line must be cut off at startup"
  tail -c 1 "$home/data/topic-board/events.jsonl" | od -An -c | grep -q '\\n' ||
    fail "events.jsonl must end with a newline after recovery"
  tb_run "$home" "$TOPIC" stop >/dev/null
  pass "a crashed board is restarted and its leftovers are cleaned up"
}

test_replaces_a_hung_board() {
  local home pid
  home=$(tb_make_service_home hung)
  tb_run "$home" "$TOPIC" propose "Hang" --goal "wait" --id hang >/dev/null
  pid=$(tb_board_pid "$home")
  kill -STOP "$pid"
  tb_run "$home" "$TOPIC" goal hang "moved on" >/dev/null || fail "a command must get past a hung board"
  assert_not_equals "$pid" "$(tb_board_pid "$home")" "the hung board must have been replaced"
  kill -0 "$pid" 2>/dev/null && fail "the hung board must be dead"
  assert_equals 1 "$(tb_board_count "$home")" "exactly one board must remain"
  tb_run "$home" "$TOPIC" stop >/dev/null
  pass "a board that stops answering is killed and replaced"
}

# A private code root in its own git repo, so the test controls its commit.
make_code_root() {
  local root=$TMP_ROOT/$1
  fm_git_init_commit "$root"
  mkdir -p "$root/bin" "$root/topic-board"
  cp "$ROOT"/bin/fm-topic.sh "$ROOT"/bin/fm-topic-lib.sh "$ROOT"/bin/fm-primary-scope-lib.sh \
    "$ROOT"/bin/fm-secondmate-registry-lib.sh "$root/bin/"
  ln -s "$ROOT/topic-board/dist" "$root/topic-board/dist"
  printf '%s\n' "$root"
}

test_replaces_the_board_when_code_or_port_changes() {
  local home root pid
  home=$(tb_make_service_home replace)
  root=$(make_code_root replace-root)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" propose "V1" --goal "old code" >/dev/null
  pid=$(tb_board_pid "$home")
  git -C "$root" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "new code"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" propose "V2" --goal "new code" >/dev/null
  assert_not_equals "$pid" "$(tb_board_pid "$home")" "a new code commit must replace the running board"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" status | grep -q "$(git -C "$root" rev-parse HEAD)" ||
    fail "the replacement must report the new commit"

  pid=$(tb_board_pid "$home")
  tb_free_port > "$home/config/topic-board-port"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" propose "V3" --goal "new port" >/dev/null
  assert_not_equals "$pid" "$(tb_board_pid "$home")" "a new port must replace the running board"
  assert_equals "$(cat "$home/config/topic-board-port")" "$(cat "$home/state/topic-board/port")" \
    "the replacement must listen on the configured port"
  assert_equals 1 "$(tb_board_count "$home")" "exactly one board must remain"

  pid=$(tb_board_pid "$home")
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" status >/dev/null
  git -C "$root" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "newer code"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" status >/dev/null
  assert_equals "$pid" "$(tb_board_pid "$home")" "status must never replace the board"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" restart >/dev/null
  assert_not_equals "$pid" "$(tb_board_pid "$home")" "restart must replace the board"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" stop >/dev/null
  pass "a code or port change replaces the board on the next command; status never does"
}

test_startup_failures_exit_69() {
  local home root out rc holder port fakebin tool
  home=$(tb_make_service_home fail-port)
  port=$(cat "$home/config/topic-board-port")
  node -e 'require("node:net").createServer().listen(Number(process.argv[1]), "127.0.0.1"); setTimeout(() => {}, 60000);' "$port" &
  holder=$!
  sleep 0.5
  rc=0
  out=$(tb_run "$home" "$TOPIC" propose "Blocked" --goal "port taken" 2>&1) || rc=$?
  kill "$holder"
  assert_equals 69 "$rc" "a port held by another program must exit 69"
  assert_equals "看板服務無法啟動：埠 $port 被別的程式佔用。在 config/topic-board-port 寫另一個埠號。這次的要求沒有寫入。" "$out" \
    "the port failure must be the one documented line"
  assert_absent "$home/data/topics.json" "a failed start must not write the topic file"

  printf 'not-a-port\n' > "$home/config/topic-board-port"
  expect_code 69 "$(tb_code "$home" "$TOPIC" propose "Bad" --goal "port")" "an invalid configured port"

  home=$(tb_make_service_home fail-dist)
  root="$TMP_ROOT/no-dist-root"
  mkdir -p "$root/bin"
  cp "$ROOT"/bin/fm-topic.sh "$ROOT"/bin/fm-topic-lib.sh "$ROOT"/bin/fm-primary-scope-lib.sh \
    "$ROOT"/bin/fm-secondmate-registry-lib.sh "$root/bin/"
  rc=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" propose "X" --goal "y" 2>&1) || rc=$?
  assert_equals 69 "$rc" "a missing build must exit 69"
  assert_contains "$out" "編譯結果不見了" "the missing-build failure must say so"

  home=$(tb_make_service_home fail-json)
  printf 'not json' > "$home/data/topics.json"
  rc=0
  out=$(tb_run "$home" "$TOPIC" propose "X" --goal "y" 2>&1) || rc=$?
  assert_equals 69 "$rc" "an unreadable topic file must exit 69"
  assert_contains "$out" "topics.json 讀不懂" "the unreadable-file failure must name the file"
  assert_equals "not json" "$(cat "$home/data/topics.json")" "an unreadable topic file must be left untouched"
  assert_equals 0 "$(tb_board_count "$home")" "a failed start must leave no board behind"

  home=$(tb_make_service_home fail-node)
  fakebin=$(fm_fakebin "$home")
  for tool in bash dirname cat env git wc tr; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  rc=0
  out=$(PATH="$fakebin" tb_run "$home" "$TOPIC" propose "X" --goal "y" 2>&1) || rc=$?
  assert_equals 69 "$rc" "a missing node must exit 69"
  assert_contains "$out" "沒有 node" "the missing-node failure must say so"
  out=$(PATH="$fakebin" tb_run "$home" "$TOPIC" status) || fail "status without node must still succeed"
  assert_contains "$out" "沒有 node" "status without node must explain why it cannot ask the board"
  expect_code 69 "$(PATH="$fakebin" tb_code "$home" "$TOPIC" stop)" "stop without node"

  home=$(tb_make_secondmate_home fail-sm sm1)
  rc=0
  out=$(tb_run "$home" "$TOPIC" propose "X" --goal "y" 2>&1) || rc=$?
  assert_equals 1 "$rc" "a socket subcommand in a secondmate home must exit 1"
  assert_contains "$out" "只在主 home" "the secondmate refusal must explain itself"
  assert_absent "$home/state/topic-board" "a secondmate home must never start a board"
  pass "each startup failure exits 69 with its one-line reason and writes nothing"
}

test_survives_ops_named_after_object_builtins() {
  local home pid op out
  home=$(tb_make_service_home builtins)
  tb_run "$home" "$TOPIC" open >/dev/null || fail "the board did not start"
  pid=$(tb_board_pid "$home")
  for op in constructor __proto__ toString valueOf hasOwnProperty; do
    out=$(tb_op "$home" "$op" 2>&1) && fail "op $op must be refused, got: $out"
    assert_contains "$out" "不認得的 op" "op $op must be answered as an unknown op"
  done
  assert_equals "$pid" "$(tb_board_pid "$home")" "the board must not be replaced"
  kill -0 "$pid" 2>/dev/null || fail "the board died on an op named after an Object builtin"
  pass "an op named after an Object builtin is an unknown op, not a crash"
}

fm_test_run test_starts_on_demand_and_stays_single test_recovers_from_a_crash test_replaces_a_hung_board \
  test_replaces_the_board_when_code_or_port_changes test_startup_failures_exit_69 \
  test_survives_ops_named_after_object_builtins
