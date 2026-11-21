#!/usr/bin/env bash
# Behavior of fm-board.sh's file-only subcommands: tag, setup, --in-home.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-board-stage-1-tag)
# shellcheck source=dispatch-plan/test/helpers.sh
. "$ROOT/dispatch-plan/test/helpers.sh"

test_tag_writes_and_is_idempotent() {
  local home out written now
  home=$(tb_make_home tag-basic)
  tb_write_topics "$home"
  out=$(tb_run "$home" "$BOARD" tag task-1 billing)
  assert_contains "$out" "ok task-1" "tag did not report success"
  grep -Eq '^billing [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$home/data/task-1/topic" ||
    fail "tag line has the wrong shape: $(cat "$home/data/task-1/topic")"
  # The line is the tag's record (the board derives a line on the topic page
  # from it), so its time must be a real time, and now.
  written=$(cut -d' ' -f2 "$home/data/task-1/topic" | jq -Rr 'fromdateiso8601') ||
    fail "tag line's time does not parse: $(cat "$home/data/task-1/topic")"
  now=$(date -u +%s)
  [ $((now - written)) -ge 0 ] && [ $((now - written)) -lt 600 ] ||
    fail "tag line's time is not when it was written: $written, now $now"
  tb_run "$home" "$BOARD" tag task-1 billing >/dev/null
  assert_equals 1 "$(wc -l < "$home/data/task-1/topic" | tr -d ' ')" "re-tagging the same topic appended a line"
  tb_run "$home" "$BOARD" tag task-1 t2 >/dev/null
  assert_equals 2 "$(wc -l < "$home/data/task-1/topic" | tr -d ' ')" "tagging a new topic did not append"
  assert_equals t2 "$(tail -n 1 "$home/data/task-1/topic" | cut -d' ' -f1)" "last line is not the newest topic"
  pass "tag appends one line per change and repeats are no-ops"
}

test_tag_validates_in_main_home() {
  local home out
  home=$(tb_make_home tag-validate)
  tb_write_topics "$home"
  out=$(tb_run "$home" "$BOARD" tag task-1 nope 2>&1) && fail "tag accepted an unknown topic"
  assert_contains "$out" "billing" "rejection did not list the usable topics"
  tb_run "$home" "$BOARD" tag task-3 idea >/dev/null ||
    fail "tag refused a leftover proposal, which the board confirms when it next starts"
  expect_code 1 "$(tb_code "$home" "$BOARD" tag task-1 gone)" "tag of an archived topic"
  expect_code 1 "$(tb_code "$home" "$BOARD" tag task-1 nope)" "tag of an unknown topic"
  expect_code 2 "$(tb_code "$home" "$BOARD" tag 'bad/id' billing)" "tag with a malformed task id"
  expect_code 2 "$(tb_code "$home" "$BOARD" tag task-1 '-x')" "tag with a malformed topic id"
  expect_code 2 "$(tb_code "$home" "$BOARD" tag task-1)" "tag with a missing argument"
  assert_absent "$home/data/task-1/topic" "a rejected tag still wrote a file"
  tb_run "$home" "$BOARD" tag task-2 old-billing >/dev/null
  assert_equals billing "$(cut -d' ' -f1 "$home/data/task-2/topic")" "merged alias was not resolved to the new id"
  pass "main-home tag accepts only live, unarchived topics and follows merged ids"
}

test_tag_without_topic_file_is_rejected() {
  local home
  home=$(tb_make_home tag-nofile)
  expect_code 1 "$(tb_code "$home" "$BOARD" tag task-1 billing)" "tag with no topic file"
  assert_absent "$home/data/task-1/topic" "tag wrote without any topic"
  pass "main-home tag refuses when there is no topic yet"
}

test_tag_from_copies_the_topic() {
  local home
  home=$(tb_make_home tag-from)
  tb_write_topics "$home"
  tb_run "$home" "$BOARD" tag old-task billing >/dev/null
  tb_run "$home" "$BOARD" tag new-task --from old-task >/dev/null
  assert_equals billing "$(cut -d' ' -f1 "$home/data/new-task/topic")" "--from did not copy the topic"
  expect_code 1 "$(tb_code "$home" "$BOARD" tag other --from untagged)" "--from an untagged source"
  pass "tag --from carries the topic to a successor task"
}

# with_port <home>: give a scratch home its own free board port, so nothing
# here can fall back to the live board's port, then print the home.
with_port() {
  tb_free_port > "$1/config/myshape-port"
  printf '%s\n' "$1"
}

# mate_tag <home> <task> <topic>: run tag there; sets TAG_OUT, TAG_ERR, TAG_RC.
mate_tag() {
  TAG_RC=0
  TAG_OUT=$(tb_run "$1" "$BOARD" tag "$2" "$3" 2> "$TMP_ROOT/tag.err") || TAG_RC=$?
  TAG_ERR=$(cat "$TMP_ROOT/tag.err")
}

# assert_checked_and_refused <home> <what>: tag with known, merged, proposed,
# archived and unknown ids, against a source holding tb_write_topics' topics.
assert_checked_and_refused() {
  local home=$1 what=$2
  mate_tag "$home" task-1 billing
  assert_equals "0 ok task-1 已標記為 billing" "$TAG_RC $TAG_OUT" "$what: a live topic must be tagged"
  assert_equals "" "$TAG_ERR" "$what: a checked tag must print nothing on stderr"
  mate_tag "$home" task-2 old-billing
  assert_equals billing "$(cut -d' ' -f1 "$home/data/task-2/topic")" "$what: a merged id must be recorded as the id it points to"
  mate_tag "$home" task-3 idea
  assert_equals 0 "$TAG_RC" "$what: a topic the board has not confirmed yet is still a topic"
  for id in gone nope; do
    mate_tag "$home" "task-$id" "$id"
    assert_equals 1 "$TAG_RC" "$what: tag $id must be refused"
    assert_contains "$TAG_ERR" "$id 不是看板上還開著的議題" "$what: the refusal must name $id"
    assert_contains "$TAG_ERR" "$(printf '  billing\t帳務重構')" "$what: the refusal must list the topics that can be used"
    assert_absent "$home/data/task-$id" "$what: a refused tag must write nothing"
  done
}

# assert_unchecked <home> <why> <what>: tag nope is written as given, with one
# stderr line saying it was not checked and why.
assert_unchecked() {
  local home=$1 why=$2 what=$3
  rm -rf "$home/data/task-u"
  mate_tag "$home" task-u nope
  assert_equals "0 ok task-u 已標記為 nope" "$TAG_RC $TAG_OUT" "$what: an unchecked tag must still be written"
  assert_equals 1 "$(printf '%s\n' "$TAG_ERR" | wc -l | tr -d ' ')" "$what: one line must say the id was not checked"
  assert_contains "$TAG_ERR" "沒有檢查 nope 是不是看板上的議題：" "$what: the line must say the id was not checked"
  assert_contains "$TAG_ERR" "$why" "$what: the line must say why"
}

test_local_mate_tag_checks_the_main_homes_file() {
  local main mate
  main=$(with_port "$(tb_make_home lm-main)")
  tb_write_topics "$main"
  mate=$(with_port "$(dp_make_local_mate lm-mate sm1 "$main")")
  assert_checked_and_refused "$mate" "local mate"
  mate_tag "$mate" task-x nope
  assert_contains "$TAG_ERR" "照主 home 的議題檔（$main/data/topics.json）" "the refusal must name the file it checked"
  assert_not_contains "$TAG_ERR" "下一份副本" "a refusal from the live file must not talk about a copy"
  pass "a local secondmate's tag is checked against the main home's topic file, read live"
}

test_remote_mate_tag_checks_a_fresh_copy() {
  local mate at
  mate=$(with_port "$(dp_make_remote_mate rm-mate far1)")
  at=$(dp_minutes_ago 59)
  dp_write_copy "$mate" "$at"
  assert_checked_and_refused "$mate" "remote mate"
  mate_tag "$mate" task-x nope
  assert_contains "$TAG_ERR" "照主 home 推來的佇列副本（${at}）" "the refusal must give the copy's time"
  assert_contains "$TAG_ERR" "議題如果是在這份副本之後才建的，等主 home 送來下一份副本再跑一次同一個指令。" \
    "the refusal must say to rerun after the next copy"
  pass "a remote secondmate's tag is checked against a copy under an hour old"
}

test_local_child_of_a_remote_mate_checks_its_copy() {
  local top child
  top=$(with_port "$(dp_make_remote_mate child-top far1)")
  dp_write_copy "$top" "$(dp_minutes_ago 3)"
  child=$(with_port "$(dp_make_local_mate child-mate kid1 "$top")")
  assert_checked_and_refused "$child" "child of a remote mate"
  pass "a local child of a remote secondmate is checked against the copy its top home keeps"
}

test_mate_tag_without_a_source_tags_and_says_why() {
  local main mate bad
  main=$(with_port "$(tb_make_home un-main)")
  mate=$(with_port "$(dp_make_local_mate un-local sm1 "$main")")
  assert_unchecked "$mate" "主 home 還沒有議題檔（$main/data/topics.json）" "no main topic file"
  printf 'not json' > "$main/data/topics.json"
  assert_unchecked "$mate" "讀不懂主 home 的 $main/data/topics.json" "an unreadable main topic file"
  mate=$(with_port "$(dp_make_remote_mate un-remote far1)")
  assert_unchecked "$mate" "這裡沒有主 home 推來的佇列副本（$mate/state/dispatch-plan/queues.json）" "no copy"
  mkdir -p "$mate/state/dispatch-plan"
  for bad in 'not json' "$(dp_copy_json 2026-13-45T99:00:00Z)" "$(dp_copy_json "$(dp_minutes_ago 1)" | jq -c 'del(.archived)')"; do
    printf '%s' "$bad" > "$mate/state/dispatch-plan/queues.json"
    assert_unchecked "$mate" "讀不懂主 home 推來的佇列副本" "a malformed copy: $bad"
  done
  dp_write_copy "$mate" "$(dp_minutes_ago 60)"
  assert_unchecked "$mate" "主 home 推來的佇列副本是 60 分鐘前的" "a copy an hour old"
  assert_unchecked "$(with_port "$(tb_make_secondmate_home un-bound sm9)")" "這裡沒有主 home 推來的佇列副本" \
    "a secondmate home with no parent record"
  expect_code 2 "$(tb_code "$mate" "$BOARD" tag task-1 'bad id')" "a malformed id is still a usage error"
  pass "a secondmate's tag is written as given, saying why, when the topic list cannot be read"
}

test_mate_tag_without_jq_tags_and_says_why() {
  local mate fakebin tool out
  mate=$(with_port "$(dp_make_remote_mate nojq-mate far1)")
  dp_write_copy "$mate" "$(dp_minutes_ago 1)"
  fakebin=$(fm_fakebin "$mate")
  for tool in bash dirname date mkdir tail cut cat env git pwd; do
    [ -e "$fakebin/$tool" ] || ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  out=$(PATH="$fakebin" tb_run "$mate" "$BOARD" tag task-1 nope 2> "$TMP_ROOT/tag.err") ||
    fail "a secondmate's tag without jq refused to write: $(cat "$TMP_ROOT/tag.err")"
  assert_equals "ok task-1 已標記為 nope" "$out" "a tag without jq must still be written"
  assert_contains "$(cat "$TMP_ROOT/tag.err")" "沒有檢查 nope 是不是看板上的議題：找不到 jq" "the line must say jq is missing"
  assert_equals nope "$(cut -d' ' -f1 "$mate/data/task-1/topic")" "the tag must be written as given"
  pass "a secondmate's tag without jq is written as given, saying so"
}

test_mate_tag_from_copies_unchecked() {
  local mate
  mate=$(with_port "$(dp_make_remote_mate from-mate far1)")
  dp_write_copy "$mate" "$(dp_minutes_ago 1)"
  mkdir -p "$mate/data/old-task"
  printf 'nope 2026-11-18T00:00:00Z\n' > "$mate/data/old-task/topic"
  tb_run "$mate" "$BOARD" tag new-task --from old-task >/dev/null 2>&1 || fail "--from failed in a secondmate home"
  assert_equals nope "$(cut -d' ' -f1 "$mate/data/new-task/topic")" "--from must copy the old task's topic as it is"
  pass "tag --from still copies the old task's topic in a secondmate home"
}

# tag and order must agree on which topic list a secondmate home has: tag
# checks exactly when order ranks by a list, except for a copy an hour old,
# which order still ranks by and tag no longer trusts.
test_tag_and_order_agree_on_the_source() {
  local mate first rc bad
  mate=$(with_port "$(dp_make_remote_mate agree-mate far1)")
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  for bad in none fresh 'not json' "$(dp_copy_json "$(dp_minutes_ago 1)" | jq -c '.queues.high = "billing"')" old; do
    rm -rf "$mate/state/dispatch-plan" "$mate/data/task-a"
    case "$bad" in
      none) ;;
      fresh) dp_write_copy "$mate" "$(dp_minutes_ago 2)" ;;
      old) dp_write_copy "$mate" "$(dp_minutes_ago 61)" ;;
      *) mkdir -p "$mate/state/dispatch-plan" && printf '%s' "$bad" > "$mate/state/dispatch-plan/queues.json" ;;
    esac
    first=$(tb_run "$mate" "$PLAN" order | head -n 1)
    rc=$(tb_code "$mate" "$BOARD" tag task-a nope)
    case "$first" in
      照主\ home\ 推來的佇列副本*)
        if [ "$bad" = old ]; then
          expect_code 0 "$rc" "tag against a copy an hour old, which order still ranks by"
        else
          expect_code 1 "$rc" "tag where order ranks by the copy ($bad)"
        fi
        ;;
      *) expect_code 0 "$rc" "tag where order has no list ($bad)" ;;
    esac
  done
  pass "tag checks against a list exactly when order ranks by one, except a copy an hour old"
}

test_tag_without_jq_warns_and_writes() {
  local home fakebin out tool
  home=$(tb_make_home tag-nojq)
  tb_write_topics "$home"
  fakebin=$(fm_fakebin "$home")
  for tool in bash dirname date mkdir tail cut cat env git; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  out=$(PATH="$fakebin" tb_run "$home" "$BOARD" tag task-1 nope 2>&1) || fail "tag without jq refused to write: $out"
  assert_contains "$out" "jq" "tag without jq did not warn"
  assert_present "$home/data/task-1/topic" "tag without jq wrote nothing"
  pass "tag without jq skips the topic check, warns, and still writes"
}

test_setup_is_idempotent() {
  local home out
  home=$(tb_make_home setup)
  rmdir "$home/config"
  out=$(tb_run "$home" "$BOARD" setup)
  assert_present "$home/config/fleet-ledger" "setup did not create the ledger flag"
  assert_contains "$out" "ok setup" "setup did not report success"
  out=$(tb_run "$home" "$BOARD" setup)
  assert_contains "$out" "本來就開著" "second setup did not report the existing flag"
  expect_code 2 "$(tb_code "$home" "$BOARD" setup extra)" "setup with an argument"
  pass "setup creates the ledger flag once"
}

test_in_home_routes_to_a_local_secondmate() {
  local home sm out
  home=$(with_port "$(tb_make_home inhome-main)")
  sm=$(with_port "$(dp_make_local_mate inhome-sm sm1 "$home")")
  tb_write_topics "$home"
  tb_write_registry "$home" "$sm"
  out=$(tb_run "$home" "$BOARD" --in-home sm1 tag task-9 billing 2>&1 >/dev/null) || fail "--in-home tag failed: $out"
  assert_equals "" "$out" "--in-home tag must be checked in both homes without a warning"
  assert_equals billing "$(cut -d' ' -f1 "$sm/data/task-9/topic")" "--in-home tag wrote to the wrong home"
  assert_absent "$home/data/task-9/topic" "--in-home tag also wrote in the main home"
  tb_run "$home" "$BOARD" --in-home sm1 setup >/dev/null
  assert_present "$sm/config/fleet-ledger" "--in-home setup did not open the secondmate ledger"
  assert_absent "$home/config/fleet-ledger" "--in-home setup opened the main ledger"
  out=$(tb_run "$home" "$BOARD" --in-home far1 tag task-9 billing 2>&1) && fail "--in-home accepted a remote secondmate"
  assert_contains "$out" "far1 是遠端的 secondmate" "remote refusal did not say the secondmate is remote"
  expect_code 1 "$(tb_code "$home" "$BOARD" --in-home nobody tag task-9 billing)" "--in-home with an unknown id"
  expect_code 2 "$(tb_code "$home" "$BOARD" --in-home sm1 list)" "--in-home with an unsupported subcommand"
  # The main home holds the topic file, so it checks the topic before it writes in the mate's home.
  out=$(tb_run "$home" "$BOARD" --in-home sm1 tag task-8 task-8 2>&1) && fail "--in-home tag accepted an unknown topic"
  assert_contains "$out" "billing" "the refusal must list the usable topics"
  assert_absent "$sm/data/task-8/topic" "a refused --in-home tag still wrote in the secondmate home"
  tb_run "$home" "$BOARD" --in-home sm1 tag task-8 old-billing >/dev/null || fail "--in-home tag of a merged id failed"
  assert_equals billing "$(cut -d' ' -f1 "$sm/data/task-8/topic")" "--in-home tag must record the id a merge points to"
  pass "--in-home runs tag and setup inside a local secondmate home only, with the main home's topic check"
}

test_in_home_answers_passes_through() {
  local home sm root out rc
  home=$(tb_make_home answers-main)
  sm=$(tb_make_secondmate_home answers-sm sm1)
  tb_write_registry "$home" "$sm"
  # A private code root whose fm-captain-hold.sh records what it was given.
  root="$TMP_ROOT/answers-root"
  mkdir -p "$root/bin"
  cp "$ROOT"/bin/fm-board.sh "$ROOT"/bin/fm-board-lib.sh "$ROOT"/bin/fm-board-migrate-lib.sh "$ROOT"/bin/fm-board-io-lib.sh "$ROOT"/bin/myshape-lib.sh \
    "$ROOT"/bin/fm-primary-scope-lib.sh "$ROOT"/bin/fm-secondmate-registry-lib.sh "$root/bin/"
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
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-board.sh" --in-home sm1 answers 2>/dev/null) || rc=$?
  assert_equals 1 "$rc" "answers did not pass the exit code through"
  assert_equals "skipped: task-1 (already closed)" "$out" "answers did not pass stdout through"
  assert_grep 'argv=answers --source myshape' "$sm/captured" "answers called fm-captain-hold.sh with the wrong argv"
  assert_grep "home=$sm" "$sm/captured" "answers ran against the wrong home"
  assert_grep "$(printf 'stdin=task-1\tyes\tyes\trelease')" "$sm/captured" "answers did not forward stdin"
  pass "--in-home answers forwards stdin, output, and exit code unchanged"
}

# bash 3.2 (the /bin/bash of macOS) reads the bytes of a non-ASCII character
# that directly follows "$name" as part of the name, and then fails on an
# unbound variable. Linux cannot show that failure, so the shape is checked.
test_variables_are_braced_before_wide_characters() {
  local script hits
  for script in fm-board.sh fm-board-lib.sh fm-dispatch-plan.sh fm-queue-source-lib.sh; do
    hits=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$ROOT/bin/$script" || true)
    assert_equals "" "$hits" "$script: write \${name} when a non-ASCII character follows the variable"
  done
  pass "no variable is directly followed by a non-ASCII character"
}

test_usage() {
  local home
  home=$(tb_make_home usage)
  expect_code 2 "$(tb_code "$home" "$BOARD" no-such-subcommand)" "unknown subcommand"
  expect_code 2 "$(tb_code "$home" "$BOARD")" "no subcommand"
  expect_code 2 "$(tb_code "$home" "$BOARD" rules extra)" "rules with an argument"
  tb_run "$home" "$BOARD" --help | grep -q 'fm-board.sh tag' || fail "--help printed no usage"
  pass "unknown subcommands are usage errors and --help prints usage"
}

fm_test_run test_tag_writes_and_is_idempotent test_tag_validates_in_main_home \
  test_tag_without_topic_file_is_rejected test_tag_from_copies_the_topic \
  test_local_mate_tag_checks_the_main_homes_file test_remote_mate_tag_checks_a_fresh_copy \
  test_local_child_of_a_remote_mate_checks_its_copy test_mate_tag_without_a_source_tags_and_says_why \
  test_mate_tag_without_jq_tags_and_says_why test_mate_tag_from_copies_unchecked \
  test_tag_and_order_agree_on_the_source test_tag_without_jq_warns_and_writes \
  test_setup_is_idempotent test_in_home_routes_to_a_local_secondmate \
  test_in_home_answers_passes_through test_variables_are_braced_before_wide_characters test_usage
