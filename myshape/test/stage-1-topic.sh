#!/usr/bin/env bash
# Behavior of myshape.sh without the board service: list, the token guard,
# the old forms, and usage.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot myshape-stage-1-topic)

test_list() {
  local home out
  home=$(tb_make_home list)
  tb_board_has_run "$home"
  out=$(tb_run "$home" "$TOPIC" list)
  assert_contains "$out" "還沒有議題" "empty list did not say so"
  tb_write_topics "$home"
  out=$(tb_run "$home" "$TOPIC" list)
  assert_contains "$out" "billing" "list missed a confirmed topic"
  assert_contains "$out" "idea" "list missed a topic that is in no queue"
  assert_not_contains "$out" "gone" "list showed an archived topic without --all"
  out=$(tb_run "$home" "$TOPIC" list --all)
  assert_contains "$out" "gone" "list --all missed the archived topic"
  out=$(tb_run "$home" "$TOPIC" list --all --json)
  assert_equals 'billing:confirmed:high:1' \
    "$(printf '%s' "$out" | jq -r '.[] | select(.id == "billing") | "\(.id):\(.status):\(.queue):\(.position)"')" \
    "list --json has the wrong shape for a queued topic"
  assert_equals 'archived' "$(printf '%s' "$out" | jq -r '.[] | select(.id == "gone") | .status')" \
    "list --json did not mark the archived topic"
  assert_equals 'confirmed:null' "$(printf '%s' "$out" | jq -r '.[] | select(.id == "idea") | "\(.status):\(.queue)"')" \
    "a leftover proposal is listed as a topic in no queue until the board confirms it"
  assert_not_contains "$out" "proposed" "list must not report a proposed state"
  pass "list prints topics, --all adds archived ones, --json is structured"
}

test_list_without_jq() {
  local home fakebin tool
  home=$(tb_make_home list-nojq)
  tb_board_has_run "$home"
  tb_write_topics "$home"
  fakebin=$(fm_fakebin "$home")
  for tool in bash dirname cat; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  expect_code 1 "$(PATH="$fakebin" tb_code "$home" "$TOPIC" list)" "list without jq"
  pass "list without jq is refused"
}

# A home whose board never ran has no token; only open may run there, so a
# secondmate home, where session start never opens a board, refuses the rest.
test_refused_where_no_board_has_run() {
  local home out rc sub
  for home in "$(tb_make_home guard-main)" "$(tb_make_secondmate_home guard-sm sm1)"; do
    tb_write_topics "$home"
    for sub in list status stop restart reset-token find which create todo; do
      rc=0
      out=$(tb_run "$home" "$TOPIC" "$sub" x 2>&1) || rc=$?
      assert_equals 1 "$rc" "$sub must be refused in a home with no board token"
      assert_equals "這裡沒有看板（找不到 state/myshape/token）；要在這裡開看板先跑 myshape.sh open。" "$out" \
        "$sub must say why and name open"
    done
    assert_absent "$home/state/myshape" "a refused command must create nothing"
  done
  pass "every subcommand but open is refused where no board has run, and writes nothing"
}

# split with tasks moved out of this command; its old form names the command
# that has it. The subcommands Firstmate's own commands took over are not this
# command's at all: an agent with rules from before the rename calls them under
# the old command name, whose stand-in answers them (fm-board/test).
test_old_forms_name_the_new_command() {
  local home out rc form expected sub
  home=$(tb_make_home old-forms)
  tb_write_topics "$home"
  while IFS='|' read -r form expected; do
    rc=0
    # shellcheck disable=SC2086 # each form is a list of words.
    out=$(tb_run "$home" "$TOPIC" $form 2>&1) || rc=$?
    assert_equals 2 "$rc" "the old form '$form' must be a usage error"
    assert_equals "myshape.sh: ${expected}（myshape.sh --help 看用法）" "$out" "the old form '$form' must name its new command"
  done <<'EOF'
split billing Part --goal g task-1|split 只建議題；要一起搬 task，改用 bin/fm-board.sh split <議題 id> <新名稱> --goal <一行> <task…>
split billing Part --goal g --id p --reason r sm1/task-1|split 只建議題；要一起搬 task，改用 bin/fm-board.sh split <議題 id> <新名稱> --goal <一行> <task…>
EOF
  for sub in tag setup install-rules order --in-home; do
    rc=0
    out=$(tb_run "$home" "$TOPIC" "$sub" x 2>&1) || rc=$?
    assert_equals 2 "$rc" "$sub must be a usage error"
    assert_equals "myshape.sh: 不認得的子命令：${sub}（myshape.sh --help 看用法）" "$out" "$sub must not be a subcommand"
  done
  assert_absent "$home/data/task-1" "an old form must write no tag"
  assert_absent "$home/config/fleet-ledger" "an old setup must not open the ledger"
  assert_absent "$home/data/captain.md" "an old install-rules must write no rules"
  assert_absent "$home/state/myshape" "an old form must not start a board"
  pass "split with tasks names its new command, and Firstmate's subcommands are not this command's"
}

# bash 3.2 (the /bin/bash of macOS) reads the bytes of a non-ASCII character
# that directly follows "$name" as part of the name, and then fails on an
# unbound variable. Linux cannot show that failure, so the shape is checked.
test_variables_are_braced_before_wide_characters() {
  local script hits
  for script in myshape.sh myshape-lib.sh fm-topic-board-read.sh; do
    hits=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$ROOT/bin/$script" || true)
    assert_equals "" "$hits" "$script: write \${name} when a non-ASCII character follows the variable"
  done
  pass "no variable is directly followed by a non-ASCII character"
}

test_usage() {
  local home out
  home=$(tb_make_home usage)
  expect_code 2 "$(tb_code "$home" "$TOPIC" no-such-subcommand)" "unknown subcommand"
  expect_code 2 "$(tb_code "$home" "$TOPIC")" "no subcommand"
  out=$(tb_run "$home" "$TOPIC" --help) || fail "--help needs no board"
  assert_contains "$out" "myshape.sh list" "--help printed no usage"
  pass "unknown subcommands are usage errors and --help prints usage"
}

fm_test_run test_list test_list_without_jq test_refused_where_no_board_has_run \
  test_old_forms_name_the_new_command test_variables_are_braced_before_wide_characters test_usage
