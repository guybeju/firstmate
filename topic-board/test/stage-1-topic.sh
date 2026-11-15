#!/usr/bin/env bash
# Behavior of the file-only fm-topic.sh subcommands: tag, list, setup, --in-home.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot topic-board-stage-1-topic)

test_tag_writes_and_is_idempotent() {
  local home out
  home=$(tb_make_home tag-basic)
  tb_write_topics "$home"
  out=$(tb_run "$home" "$TOPIC" tag task-1 billing)
  assert_contains "$out" "ok task-1" "tag did not report success"
  grep -Eq '^billing [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$home/data/task-1/topic" ||
    fail "tag line has the wrong shape: $(cat "$home/data/task-1/topic")"
  tb_run "$home" "$TOPIC" tag task-1 billing >/dev/null
  assert_equals 1 "$(wc -l < "$home/data/task-1/topic" | tr -d ' ')" "re-tagging the same topic appended a line"
  tb_run "$home" "$TOPIC" tag task-1 t2 >/dev/null
  assert_equals 2 "$(wc -l < "$home/data/task-1/topic" | tr -d ' ')" "tagging a new topic did not append"
  assert_equals t2 "$(tail -n 1 "$home/data/task-1/topic" | cut -d' ' -f1)" "last line is not the newest topic"
  pass "tag appends one line per change and repeats are no-ops"
}

test_tag_validates_in_main_home() {
  local home out
  home=$(tb_make_home tag-validate)
  tb_write_topics "$home"
  out=$(tb_run "$home" "$TOPIC" tag task-1 idea 2>&1) && fail "tag accepted a proposed topic"
  assert_contains "$out" "billing" "rejection did not list the usable topics"
  expect_code 1 "$(tb_code "$home" "$TOPIC" tag task-1 gone)" "tag of an archived topic"
  expect_code 1 "$(tb_code "$home" "$TOPIC" tag task-1 nope)" "tag of an unknown topic"
  expect_code 2 "$(tb_code "$home" "$TOPIC" tag 'bad/id' billing)" "tag with a malformed task id"
  expect_code 2 "$(tb_code "$home" "$TOPIC" tag task-1 '-x')" "tag with a malformed topic id"
  expect_code 2 "$(tb_code "$home" "$TOPIC" tag task-1)" "tag with a missing argument"
  assert_absent "$home/data/task-1/topic" "a rejected tag still wrote a file"
  tb_run "$home" "$TOPIC" tag task-2 old-billing >/dev/null
  assert_equals billing "$(cut -d' ' -f1 "$home/data/task-2/topic")" "merged alias was not resolved to the new id"
  pass "main-home tag accepts only confirmed, unarchived topics and follows merged ids"
}

test_tag_without_topic_file_is_rejected() {
  local home
  home=$(tb_make_home tag-nofile)
  expect_code 1 "$(tb_code "$home" "$TOPIC" tag task-1 billing)" "tag with no topic file"
  assert_absent "$home/data/task-1/topic" "tag wrote without any confirmed topic"
  pass "main-home tag refuses when no topic is confirmed yet"
}

test_tag_from_copies_the_topic() {
  local home
  home=$(tb_make_home tag-from)
  tb_write_topics "$home"
  tb_run "$home" "$TOPIC" tag old-task billing >/dev/null
  tb_run "$home" "$TOPIC" tag new-task --from old-task >/dev/null
  assert_equals billing "$(cut -d' ' -f1 "$home/data/new-task/topic")" "--from did not copy the topic"
  expect_code 1 "$(tb_code "$home" "$TOPIC" tag other --from untagged)" "--from an untagged source"
  pass "tag --from carries the topic to a successor task"
}

test_tag_in_secondmate_home_checks_format_only() {
  local home
  home=$(tb_make_secondmate_home tag-sm sm1)
  tb_run "$home" "$TOPIC" tag task-1 anything-goes >/dev/null || fail "secondmate tag rejected a well-formed id"
  assert_equals anything-goes "$(cut -d' ' -f1 "$home/data/task-1/topic")" "secondmate tag wrote the wrong id"
  expect_code 2 "$(tb_code "$home" "$TOPIC" tag task-1 'bad id')" "secondmate tag with a malformed id"
  pass "secondmate-home tag only checks the id format"
}

test_tag_without_jq_warns_and_writes() {
  local home fakebin out tool
  home=$(tb_make_home tag-nojq)
  tb_write_topics "$home"
  fakebin=$(fm_fakebin "$home")
  for tool in bash dirname date mkdir tail cut cat env git; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  out=$(PATH="$fakebin" tb_run "$home" "$TOPIC" tag task-1 nope 2>&1) || fail "tag without jq refused to write: $out"
  assert_contains "$out" "jq" "tag without jq did not warn"
  assert_present "$home/data/task-1/topic" "tag without jq wrote nothing"
  expect_code 1 "$(PATH="$fakebin" tb_code "$home" "$TOPIC" list)" "list without jq"
  pass "tag without jq skips the confirmed check, warns, and still writes"
}

test_list() {
  local home out
  home=$(tb_make_home list)
  out=$(tb_run "$home" "$TOPIC" list)
  assert_contains "$out" "還沒有議題" "empty list did not say so"
  tb_write_topics "$home"
  out=$(tb_run "$home" "$TOPIC" list)
  assert_contains "$out" "billing" "list missed a confirmed topic"
  assert_contains "$out" "idea" "list missed a proposed topic"
  assert_not_contains "$out" "gone" "list showed an archived topic without --all"
  out=$(tb_run "$home" "$TOPIC" list --all)
  assert_contains "$out" "gone" "list --all missed the archived topic"
  out=$(tb_run "$home" "$TOPIC" list --all --json)
  assert_equals 'billing:confirmed:high:1' \
    "$(printf '%s' "$out" | jq -r '.[] | select(.id == "billing") | "\(.id):\(.status):\(.queue):\(.position)"')" \
    "list --json has the wrong shape for a queued topic"
  assert_equals 'archived' "$(printf '%s' "$out" | jq -r '.[] | select(.id == "gone") | .status')" \
    "list --json did not mark the archived topic"
  assert_equals 'null' "$(printf '%s' "$out" | jq -r '.[] | select(.id == "idea") | .queue')" \
    "a proposed topic must not be in a queue"
  home=$(tb_make_secondmate_home list-sm sm1)
  out=$(tb_run "$home" "$TOPIC" list 2>&1) && fail "list ran in a secondmate home"
  assert_contains "$out" "只在主 home" "secondmate list did not explain the refusal"
  pass "list prints topics, --all adds archived ones, --json is structured"
}

test_setup_is_idempotent() {
  local home out
  home=$(tb_make_home setup)
  rmdir "$home/config"
  out=$(tb_run "$home" "$TOPIC" setup)
  assert_present "$home/config/fleet-ledger" "setup did not create the ledger flag"
  assert_contains "$out" "ok setup" "setup did not report success"
  out=$(tb_run "$home" "$TOPIC" setup)
  assert_contains "$out" "本來就開著" "second setup did not report the existing flag"
  pass "setup creates the ledger flag once"
}

test_in_home_routes_to_a_local_secondmate() {
  local home sm out
  home=$(tb_make_home inhome-main)
  sm=$(tb_make_secondmate_home inhome-sm sm1)
  tb_write_topics "$home"
  tb_write_registry "$home" "$sm"
  tb_run "$home" "$TOPIC" --in-home sm1 tag task-9 billing >/dev/null || fail "--in-home tag failed"
  assert_equals billing "$(cut -d' ' -f1 "$sm/data/task-9/topic")" "--in-home tag wrote to the wrong home"
  assert_absent "$home/data/task-9/topic" "--in-home tag also wrote in the main home"
  tb_run "$home" "$TOPIC" --in-home sm1 setup >/dev/null
  assert_present "$sm/config/fleet-ledger" "--in-home setup did not open the secondmate ledger"
  assert_absent "$home/config/fleet-ledger" "--in-home setup opened the main ledger"
  out=$(tb_run "$home" "$TOPIC" --in-home far1 tag task-9 billing 2>&1) && fail "--in-home accepted a remote secondmate"
  assert_contains "$out" "far1 是遠端的 secondmate" "remote refusal did not say the secondmate is remote"
  expect_code 1 "$(tb_code "$home" "$TOPIC" --in-home nobody tag task-9 billing)" "--in-home with an unknown id"
  expect_code 2 "$(tb_code "$home" "$TOPIC" --in-home sm1 list)" "--in-home with an unsupported subcommand"
  pass "--in-home runs tag and setup inside a local secondmate home only"
}

test_in_home_answers_passes_through() {
  local home sm root out rc
  home=$(tb_make_home answers-main)
  sm=$(tb_make_secondmate_home answers-sm sm1)
  tb_write_registry "$home" "$sm"
  # A private code root whose fm-captain-hold.sh records what it was given.
  root="$TMP_ROOT/answers-root"
  mkdir -p "$root/bin"
  cp "$ROOT"/bin/fm-topic.sh "$ROOT"/bin/fm-topic-lib.sh "$ROOT"/bin/fm-primary-scope-lib.sh \
    "$ROOT"/bin/fm-secondmate-registry-lib.sh "$root/bin/"
  cat > "$root/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
{ printf 'argv=%s\n' "$*"; printf 'home=%s\n' "$FM_HOME"; printf 'stdin=%s\n' "$(cat)"; } > "$FM_HOME/captured"
echo "skipped: task-1 (already closed)"
echo "error text" >&2
exit 1
SH
  chmod +x "$root/bin/fm-captain-hold.sh"
  rc=0
  out=$(printf 'task-1\tyes\tyes\trelease\n' |
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" --in-home sm1 answers 2>/dev/null) || rc=$?
  assert_equals 1 "$rc" "answers did not pass the exit code through"
  assert_equals "skipped: task-1 (already closed)" "$out" "answers did not pass stdout through"
  assert_grep 'argv=answers --source topic-board' "$sm/captured" "answers called fm-captain-hold.sh with the wrong argv"
  assert_grep "home=$sm" "$sm/captured" "answers ran against the wrong home"
  assert_grep "$(printf 'stdin=task-1\tyes\tyes\trelease')" "$sm/captured" "answers did not forward stdin"
  pass "--in-home answers forwards stdin, output, and exit code unchanged"
}

test_usage() {
  local home
  home=$(tb_make_home usage)
  expect_code 2 "$(tb_code "$home" "$TOPIC" no-such-subcommand)" "unknown subcommand"
  expect_code 2 "$(tb_code "$home" "$TOPIC")" "no subcommand"
  tb_run "$home" "$TOPIC" --help | grep -q 'fm-topic.sh' || fail "--help printed no usage"
  pass "unknown subcommands are usage errors and --help prints usage"
}

fm_test_run test_tag_writes_and_is_idempotent test_tag_validates_in_main_home \
  test_tag_without_topic_file_is_rejected test_tag_from_copies_the_topic \
  test_tag_in_secondmate_home_checks_format_only test_tag_without_jq_warns_and_writes \
  test_list test_setup_is_idempotent test_in_home_routes_to_a_local_secondmate \
  test_in_home_answers_passes_through test_usage
