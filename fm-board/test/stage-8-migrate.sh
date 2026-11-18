#!/usr/bin/env bash
# fm-board.sh migrate-myshape: a home moves from the board's names before the
# rename to myshape in one command, a rerun after any interruption finishes the
# job, refusals change nothing, and --undo puts back what the move changed.
#
# Every case runs on a scratch home under TMP_ROOT with a scratch code root:
# the migration tidies the code root's topic-board/ directory, so it never runs
# against this checkout. The old board is the base commit's own board files,
# exported with git archive and committed into a scratch board-only root; it
# reads its port under the old name, the new code under the new name, and every
# home holds a free port under each name it needs, never the live board's.
# shellcheck disable=SC2016 # jq filters are literal text.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"

BASE=5324261c
BASE_BOARD_FILES="bin/fm-topic.sh bin/fm-topic-lib.sh topic-board/dist topic-board/public topic-board/package.json"
LIVE_BOARD_PORT=47819
for tool in jq node git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null || { echo "not ok - base $BASE is not in this checkout" >&2; exit 1; }
TMP_ROOT=$(fm_test_tmproot fm-board-s8m)
case "$TMP_ROOT" in /*) ;; *) echo "not ok - no scratch root" >&2; exit 1 ;; esac
trap 'tb_stop_boards; fm_test_cleanup' EXIT

OLD_ROOT=$TMP_ROOT/old-board
tb_make_board_root "$OLD_ROOT" "$BASE" "$BASE_BOARD_FILES" >/dev/null
SHIMS=$TMP_ROOT/shims
mkdir -p "$SHIMS"

# make_code_root <name>: a scratch code root the migration may tidy: the
# board's build and the rules templates of this checkout, a real myshape/
# directory to move leftovers into, and its own git history.
make_code_root() {
  local root=$TMP_ROOT/$1
  mkdir -p "$root/myshape" "$root/fm-board"
  ln -s "$ROOT/myshape/dist" "$root/myshape/dist"
  ln -s "$ROOT/myshape/public" "$root/myshape/public"
  ln -s "$ROOT/fm-board/rules" "$root/fm-board/rules"
  tb_commit_root "$root" "scratch code root" >/dev/null
  printf '%s\n' "$root"
}

# assert_scratch <home>: the home is under the scratch root and every port file
# it has holds a port other than the live board's.
assert_scratch() {
  local file port
  case "$1/" in "$TMP_ROOT"/*) ;; *) fail "home $1 is outside the scratch root $TMP_ROOT" ;; esac
  for file in "$1/config/topic-board-port" "$1/config/myshape-port"; do
    [ -f "$file" ] || continue
    port=$(cat "$file")
    [ "$port" != "$LIVE_BOARD_PORT" ] || fail "$file holds the live board's port"
  done
}

# mig <home> <code-root> [migrate-myshape arguments...]: run the migration.
mig() {
  local home=$1 root=$2
  shift 2
  assert_scratch "$home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$SHIMS:$PATH" "$BOARD" migrate-myshape "$@"
}

mig_code() {  # like mig, output discarded; prints the exit code.
  local rc=0
  mig "$@" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# new <home> <code-root> <myshape.sh arguments...>
new() {
  local home=$1 root=$2
  shift 2
  assert_scratch "$home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" MYSHAPE_LOCAL_MS=300 "$ROOT/bin/myshape.sh" "$@"
}

# old <home> <fm-topic.sh arguments...>: the base's own board command.
old() {
  local home=$1
  shift
  assert_scratch "$home"
  env -u FM_ROOT_OVERRIDE FM_HOME="$home" FM_TOPIC_BOARD_LOCAL_MS=300 "$OLD_ROOT/bin/fm-topic.sh" "$@"
}

# old_home <name>: a main home the base's board has run in, with its port
# under both names, topics, a summary, the base's rules blocks under the old
# marker, two rules backups the base's installer left, and a backlog.
old_home() {
  local home port
  home=$(tb_make_home "$1")
  port=$(tb_free_port)
  printf '%s\n' "$port" > "$home/config/topic-board-port"
  printf '%s\n' "$port" > "$home/config/myshape-port"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  old "$home" open >/dev/null || fail "the old board did not start in $home"
  old "$home" create "Old A" --goal a --id old-a >/dev/null || fail "the old board did not create a topic"
  old "$home" create "Old B" --goal b --id old-b --queue later >/dev/null
  printf '做到一半。\n' | old "$home" summary t1 report - >/dev/null || fail "the old board did not store a summary"
  { printf '# 我的偏好\n\n'; git -C "$ROOT" show "$BASE:fm-board/rules/captain.block.md.tmpl"; printf '\n- 最後一行\n'; } \
    > "$home/data/captain.md"
  { git -C "$ROOT" show "$BASE:fm-board/rules/captain-shared.header.md.tmpl"
    git -C "$ROOT" show "$BASE:fm-board/rules/captain-shared.block.md.tmpl"; } > "$home/data/captain-shared.md"
  mkdir -p "$home/state/topic-board/rules-backup"
  printf 'old main rules\n' > "$home/state/topic-board/rules-backup/captain.md.20261101T000000Z"
  printf 'old shared rules\n' > "$home/state/topic-board/rules-backup/captain-shared.md.20261101T000000Z"
  printf '%s\n' "$home"
}

# ready_to_migrate <home>: the port under the new name is dropped, so that the
# move has only the old one to move: the migration refuses a pair whose old
# and new names are both there. Only the old code runs until the move, and it
# reads the old name, which must hold a scratch port.
ready_to_migrate() {
  local port
  port=$(cat "$1/config/topic-board-port")
  case "$port" in '' | "$LIVE_BOARD_PORT") fail "$1 has no scratch port under the old name" ;; esac
  rm "$1/config/myshape-port"
}

# leftovers <code-root>: what a checkout of the old tree installed.
leftovers() {
  mkdir -p "$1/topic-board/node_modules/pkg" "$1/topic-board/coverage" "$1/topic-board/.metrics"
  printf 'module\n' > "$1/topic-board/node_modules/pkg/index.js"
  printf 'report\n' > "$1/topic-board/coverage/lcov.info"
  printf 'crap\n' > "$1/topic-board/.metrics/crap.json"
}

# tree_sums <dir>: "<sha256>  <path>" for every file under <dir>, sorted.
tree_sums() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"
  done)
}

# home_sums <home> <code-root>: every file the move may touch and --undo must
# put back. Left out: the service's pid, its log and the port it last listened
# on, which the board itself rewrites when it starts or stops; and
# state/fm-board/, where the backups S8 took stay after --undo as copies of
# the files --undo restored.
home_sums() {
  {
    tree_sums "$1/data"
    tree_sums "$1/config"
    (cd "$1/state" && find . -type f ! -path './topic-board/pid' ! -path './topic-board/service.log' \
      ! -path './topic-board/port' ! -path './fm-board/*' | LC_ALL=C sort |
      while IFS= read -r f; do printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"; done)
    tree_sums "$2/topic-board" 2>/dev/null || true
  }
}

# mv_shim <mode> <n>: the n-th mv the migration runs ends the migration there:
# "after" does that mv first, "before" does not, "corrupt" does it and then
# appends to a moved events file, as if the move had not kept it.
mv_shim() {
  printf '0\n' > "$SHIMS/mv.count"
  cat > "$SHIMS/mv" <<SH
#!/bin/sh
n=\$((\$(cat "$SHIMS/mv.count") + 1))
printf '%s\n' "\$n" > "$SHIMS/mv.count"
if [ "\$n" -ne $2 ]; then exec /bin/mv "\$@"; fi
case "$1" in
  before) kill -KILL "\$PPID"; exit 1 ;;
  after) /bin/mv "\$@"; kill -KILL "\$PPID"; exit 0 ;;
  corrupt) /bin/mv "\$@"; for f in "\$@"; do :; done; printf 'x\n' >> "\$f/events.jsonl"; exit 0 ;;
esac
SH
  chmod +x "$SHIMS/mv"
}

no_shims() {
  rm -f "$SHIMS/mv" "$SHIMS/mv.count"
}

assert_moved() {  # <home> <code-root> <old-pid>
  local home=$1 root=$2
  assert_absent "$home/state/topic-board" "the old state directory must be gone"
  assert_absent "$home/data/topic-board" "the old data directory must be gone"
  assert_absent "$home/config/topic-board-port" "the old port file must be gone"
  assert_present "$home/state/myshape/token" "the token must have moved"
  kill -0 "$3" 2>/dev/null && fail "the old service must be stopped"
  assert_equals 1 "$(tb_board_count "$home")" "exactly one board must serve the home"
  assert_contains "$(new "$home" "$root" status)" "看板服務：在跑" "the new board must run"
  assert_contains "$(new "$home" "$root" status)" "程式版本：$(git -C "$root" rev-parse HEAD)" "the board must run the code root's commit"
  assert_equals "規則：captain.md 和範本相同（v10）；captain-shared.md 和範本相同（v4）" "$(tb_run "$home" "$BOARD" rules)" \
    "both rules files must hold the current blocks"
  assert_equals 0 "$(cat "$home/data/captain.md" "$home/data/captain-shared.md" | grep -c '<!-- topic-board:')" \
    "no old marker may be left"
  assert_equals "已搬完" "$(mig "$home" "$root" --check)" "--check must report the move done"
}

test_moves_a_home_end_to_end() {
  local home root out pid token port before
  home=$(old_home e2e)
  root=$(make_code_root e2e-root)
  leftovers "$root"
  pid=$(cat "$home/state/topic-board/pid")
  token=$(sha256sum < "$home/state/topic-board/token")
  port=$(cat "$home/config/topic-board-port")
  ready_to_migrate "$home"
  before=$(tree_sums "$home/data"; tree_sums "$home/config")
  out=$(mig "$home" "$root" --check) || fail "--check refused a home it can move: $out"
  assert_contains "$out" "要搬：$home/state/topic-board → $home/state/myshape" "--check must list the state move"
  assert_contains "$out" "要停：舊的看板服務（pid $pid）" "--check must name the running service"
  assert_contains "$out" "要換：captain.md 裡舊標記的規則區塊" "--check must list the rules"
  assert_contains "$out" "要清：$root/topic-board 裡的" "--check must list the leftovers"
  kill -0 "$pid" 2>/dev/null || fail "--check must not stop the service"
  assert_equals "$before" "$(tree_sums "$home/data"; tree_sums "$home/config")" "--check must write nothing"
  assert_absent "$home/state/fm-board" "--check must write nothing"
  out=$(mig "$home" "$root") || fail "the migration failed: $out"
  assert_contains "$out" "S6：" "the run must check the manifest"
  assert_contains "$out" "和搬之前相同" "the run must report the counts unchanged"
  assert_contains "$out" "S10：看板在跑：http://127.0.0.1:$port/#t=" "the run must print the board's URL"
  assert_contains "$out" "已搬完" "the run must end with 已搬完"
  assert_moved "$home" "$root" "$pid"
  assert_equals "$token" "$(sha256sum < "$home/state/myshape/token")" "the token must be the same"
  assert_equals "$port" "$(cat "$home/config/myshape-port")" "the port must be the same"
  assert_equals "old-a" "$(new "$home" "$root" list --json | jq -r '[.[] | select(.queue == "normal") | .id] | join(" ")')" \
    "the new board must read the old topics"
  grep -q '"task":"t1"' "$home/data/myshape/summaries.jsonl" || fail "the summary must have moved"
  assert_equals "old main rules" "$(cat "$home/state/fm-board/rules-backup/captain.md.20261101T000000Z")" "the old backups must have moved"
  assert_absent "$home/state/myshape/rules-backup" "no rules backup may be left in the board's directory"
  assert_absent "$root/topic-board" "the code root's old directory must be gone"
  assert_equals "module" "$(cat "$root/myshape/node_modules/pkg/index.js")" "the leftovers must have moved"
  assert_equals "# 我的偏好" "$(head -n 1 "$home/data/captain.md")" "the captain's own lines must be kept"
  assert_equals "- 最後一行" "$(tail -n 1 "$home/data/captain.md")" "the captain's own lines must be kept"
  out=$(mig "$home" "$root") || fail "a second run failed: $out"
  assert_contains "$out" "已搬完" "a second run must change nothing and say so"
  new "$home" "$root" stop >/dev/null
  pass "one command stops the old board, moves its files with an equal manifest, swaps the rules, and starts the board"
}

test_undo_puts_everything_back() {
  local home root before out
  home=$(old_home undo)
  root=$(make_code_root undo-root)
  leftovers "$root"
  old "$home" stop >/dev/null
  ready_to_migrate "$home"
  before=$(home_sums "$home" "$root")
  mig "$home" "$root" >/dev/null || fail "the migration failed"
  out=$(mig "$home" "$root" --undo) || fail "--undo failed: $out"
  assert_contains "$out" "已還原" "--undo must say it is done"
  assert_equals "$before" "$(home_sums "$home" "$root")" "--undo must put back every file byte for byte"
  assert_equals 0 "$(tb_board_count "$home")" "--undo must leave no board running"
  assert_absent "$home/state/fm-board/migrate-myshape.journal" "--undo must delete the journal"
  assert_contains "$(mig "$home" "$root" --check)" "要搬：" "after --undo the move must be pending again"
  cp "$home/config/topic-board-port" "$home/config/myshape-port"
  old "$home" open >/dev/null || fail "the old board must start again after --undo"
  assert_contains "$(old "$home" list)" "old-a" "the old board must find its topics after --undo"
  ready_to_migrate "$home"
  mig "$home" "$root" >/dev/null || fail "migrating again after --undo failed"
  assert_contains "$(mig "$home" "$root" --check)" "已搬完" "migrating again after --undo must finish"
  new "$home" "$root" stop >/dev/null
  pass "--undo puts back every file byte for byte, the old board runs again, and the move can be repeated"
}

# undo_after_edit: a rules file changed after the move gets its old block back
# and keeps the change.
test_undo_keeps_later_edits_outside_the_block() {
  local home root
  home=$(old_home undo-edit)
  root=$(make_code_root undo-edit-root)
  old "$home" stop >/dev/null
  ready_to_migrate "$home"
  mig "$home" "$root" >/dev/null || fail "the migration failed"
  printf -- '- 後來加的一行\n' >> "$home/data/captain.md"
  mig "$home" "$root" --undo >/dev/null || fail "--undo failed"
  assert_equals "- 後來加的一行" "$(tail -n 1 "$home/data/captain.md")" "a later edit outside the block must be kept"
  assert_equals 1 "$(grep -c '^<!-- topic-board:begin v9' "$home/data/captain.md")" "the old block must be back"
  assert_equals 0 "$(grep -c '<!-- myshape:' "$home/data/captain.md")" "the new block must be gone"
  pass "--undo on a rules file edited since the move puts the old block back and keeps the edit"
}

# rules_left <home> <old blocks left>: how many old-marker blocks the two rules files hold.
rules_left() {
  assert_equals "$2" "$(cat "$1/data/captain.md" "$1/data/captain-shared.md" | grep -c '^<!-- topic-board:begin')" \
    "$2 old rules blocks must be left"
}

# interrupted <name> <mode> <n> <what> <there> <gone> <old rules blocks left>:
# kill the run at the n-th mv, check it stopped where <what> says (<there>
# exists, <gone> does not, both relative to the home, and that many old rules
# blocks are left), then rerun.
interrupted() {
  local name=$1 home root rc out
  home=$(old_home "$name")
  root=$(make_code_root "$name-root")
  leftovers "$root"
  old "$home" stop >/dev/null
  ready_to_migrate "$home"
  mv_shim "$2" "$3"
  rc=$(mig_code "$home" "$root")
  assert_equals "$3" "$(cat "$SHIMS/mv.count")" "the run must have reached the mv it is cut at ($4)"
  no_shims
  assert_not_equals 0 "$rc" "the run interrupted $4 must not succeed"
  assert_present "$home/$5" "the run must have stopped $4"
  assert_absent "$home/$6" "the run must have stopped $4"
  rules_left "$home" "$7"
  assert_present "$home/state/fm-board/migrate-myshape.journal" "the journal must be kept ($4)"
  out=$(mig "$home" "$root") || fail "rerunning after an interruption $4 failed: $out"
  assert_contains "$out" "已搬完" "the rerun after an interruption $4 must finish"
  assert_contains "$(mig "$home" "$root" --check)" "已搬完" "--check after the rerun ($4)"
  assert_equals 1 "$(tb_board_count "$home")" "exactly one board after the rerun ($4)"
  assert_equals "old main rules" "$(cat "$home/state/fm-board/rules-backup/captain.md.20261101T000000Z")" \
    "the old backups must be in place after the rerun ($4)"
  assert_equals "module" "$(cat "$root/myshape/node_modules/pkg/index.js")" "the leftovers must be moved after the rerun ($4)"
  new "$home" "$root" stop >/dev/null
}

# The mv calls of a run in these homes: S2 moves 2 backups (1, 2), S0 puts
# its manifest in place (3), S3 (4), S4 (5), S5 (6), S8 installs 2 files
# (7, 8), S9 moves 3 entries (9 to 11).
test_a_rerun_finishes_after_each_interruption() {
  local home root rc
  interrupted cut-s1 before 1 "after S1" state/topic-board/rules-backup/captain.md.20261101T000000Z state/myshape 2
  interrupted cut-s3 after 4 "after S3" state/myshape data/myshape 2
  interrupted cut-s4 after 5 "after S4" data/myshape config/myshape-port 2
  interrupted cut-s5 after 6 "after S5" config/myshape-port config/topic-board-port 2
  interrupted cut-s8 after 7 "inside S8" config/myshape-port state/myshape/pid 1
  interrupted cut-s10 after 11 "before S10" state/myshape/token state/myshape/pid 0
  home=$(old_home cut-midway)
  root=$(make_code_root cut-midway-root)
  old "$home" stop >/dev/null
  ready_to_migrate "$home"
  mv_shim after 4
  mig_code "$home" "$root" >/dev/null
  no_shims
  rc=0
  new "$home" "$root" list >/dev/null 2>&1 || rc=$?
  assert_equals 69 "$rc" "the board must refuse while an old name is left"
  pass "a run killed after S1, after each single move, inside S8 or before S10 is finished by running it again"
}

test_a_changed_file_stops_the_move() {
  local home root out rc=0
  home=$(old_home corrupt)
  root=$(make_code_root corrupt-root)
  old "$home" stop >/dev/null
  ready_to_migrate "$home"
  mv_shim corrupt 5
  out=$(mig "$home" "$root" 2>&1) || rc=$?
  no_shims
  assert_equals 1 "$rc" "a manifest mismatch must fail the run"
  assert_contains "$out" "data/events.jsonl" "the mismatch must name the file"
  assert_contains "$out" "S6：搬過去的檔和搬之前不一樣" "the mismatch must be explained"
  assert_equals 1 "$(grep -c '<!-- topic-board:begin' "$home/data/captain.md")" "nothing after S6 may run"
  assert_equals 0 "$(tb_board_count "$home")" "no board may start after a mismatch"
  mig "$home" "$root" --undo >/dev/null || fail "--undo after a mismatch failed"
  assert_present "$home/data/topic-board/events.jsonl" "--undo must move the data back"
  assert_present "$home/state/topic-board/token" "--undo must move the state back"
  pass "a moved file that differs from the baseline stops the run before the rules, and --undo moves it back"
}

test_both_markers_and_a_broken_marker() {
  local home root out rc=0
  home=$(old_home both)
  root=$(make_code_root both-root)
  old "$home" stop >/dev/null
  ready_to_migrate "$home"
  cat "$ROOT/fm-board/rules/captain.block.md.tmpl" >> "$home/data/captain.md"
  mig "$home" "$root" >/dev/null || fail "the migration failed with both markers"
  assert_equals "規則：captain.md 和範本相同（v10）；captain-shared.md 和範本相同（v4）" "$(tb_run "$home" "$BOARD" rules)" \
    "a file with both markers must end with only the new block"
  new "$home" "$root" stop >/dev/null

  home=$(old_home broken)
  root=$(make_code_root broken-root)
  old "$home" stop >/dev/null
  ready_to_migrate "$home"
  printf '<!-- topic-board:begin v9 -->\n- 沒有結尾\n' > "$home/data/captain.md"
  assert_contains "$(mig "$home" "$root" --check)" "不能換：captain.md 的標記不成對" "--check must show the broken file"
  expect_code 1 "$(mig_code "$home" "$root" --check)" "--check with a broken file"
  out=$(mig "$home" "$root" 2>&1) || rc=$?
  assert_equals 1 "$rc" "a broken rules file must fail the run"
  assert_not_contains "$out" "已搬完" "a run that left a file must not say 已搬完"
  assert_equals "$(printf '<!-- topic-board:begin v9 -->\n- 沒有結尾')" "$(cat "$home/data/captain.md")" "the broken file must be left alone"
  assert_present "$home/state/myshape/token" "everything else must still move"
  assert_contains "$(tb_run "$home" "$BOARD" rules)" "captain-shared.md 和範本相同（v4）" "the other file must be replaced"
  printf '# 整理好了\n' > "$home/data/captain.md"
  assert_contains "$(mig "$home" "$root")" "已搬完" "after the file is fixed a rerun must finish"
  new "$home" "$root" stop >/dev/null
  pass "a file with both markers keeps only the new block; a broken file is left, reported, and finished by a rerun"
}

test_refusals_change_nothing() {
  local home root before out rc
  home=$(old_home refuse)
  root=$(make_code_root refuse-root)
  old "$home" stop >/dev/null
  mkdir -p "$home/state/myshape"
  before=$(tree_sums "$home")
  rc=0
  out=$(mig "$home" "$root" 2>&1) || rc=$?
  assert_equals 1 "$rc" "old and new both present must be refused"
  assert_contains "$out" "不能搬：$home/state/topic-board 和 $home/state/myshape 都在" "the refusal must name both paths"
  assert_contains "$out" "不能搬：$home/config/topic-board-port 和 $home/config/myshape-port 都在" "the port pair too"
  assert_contains "$out" "什麼都沒有搬" "the refusal must say nothing moved"
  assert_equals "$before" "$(tree_sums "$home")" "a refused run must change nothing"
  rmdir "$home/state/myshape"
  ready_to_migrate "$home"
  sleep 300 &
  printf '%s\n' "$!" > "$home/state/topic-board/pid"
  rc=0
  out=$(mig "$home" "$root" 2>&1) || rc=$?
  kill "$(cat "$home/state/topic-board/pid")" 2>/dev/null || true
  assert_equals 1 "$rc" "a pid file naming another process must be refused"
  assert_contains "$out" "不能停：state/topic-board/pid 指的是別的程序" "the refusal must say why"
  assert_present "$home/state/topic-board/token" "nothing may move after that refusal"
  rm "$home/state/topic-board/pid"
  mkdir -p "$home/state/fm-board/migrate-myshape.lock"
  sleep 300 &
  printf '%s\n' "$!" > "$home/state/fm-board/migrate-myshape.lock/pid"
  rc=0
  out=$(mig "$home" "$root" 2>&1) || rc=$?
  kill "$(cat "$home/state/fm-board/migrate-myshape.lock/pid")" 2>/dev/null || true
  assert_equals 1 "$rc" "a second run at the same time must be refused"
  assert_contains "$out" "另一個 migrate-myshape" "the lock refusal must say why"
  assert_present "$home/state/topic-board/token" "nothing may move while the lock is held"
  assert_contains "$(mig "$home" "$root")" "已搬完" "once the holder is gone the lock is taken over"
  new "$home" "$root" stop >/dev/null
  expect_code 2 "$(mig_code "$home" "$root" --frobnicate)" "an unknown option"
  pass "old and new both present, a foreign pid, and a held lock are refused and change nothing"
}

test_a_secondmate_home_only_tidies_the_checkout() {
  local home root out before
  home=$(tb_make_secondmate_home sm-home sm1)
  root=$(make_code_root sm-root)
  leftovers "$root"
  { git -C "$ROOT" show "$BASE:fm-board/rules/captain-shared.header.md.tmpl"
    git -C "$ROOT" show "$BASE:fm-board/rules/captain-shared.block.md.tmpl"; } > "$home/data/captain-shared.md"
  before=$(tree_sums "$home/data")
  out=$(mig "$home" "$root") || fail "the migration failed in a secondmate home: $out"
  assert_contains "$out" "secondmate home：沒有看板的檔，不用搬" "a secondmate home must say there is nothing to move"
  assert_contains "$out" "已搬完" "a secondmate home must finish"
  assert_equals "$before" "$(tree_sums "$home/data")" "the shared copy must not be touched"
  assert_absent "$root/topic-board" "the code root must be tidied"
  assert_equals 0 "$(tb_board_count "$home")" "no board may start in a secondmate home"
  assert_absent "$home/state/myshape" "nothing of the board may be created"
  mig "$home" "$root" --undo >/dev/null || fail "--undo failed in a secondmate home"
  assert_equals "module" "$(cat "$root/topic-board/node_modules/pkg/index.js")" "--undo must move the leftovers back"
  pass "in a secondmate home only the checkout is tidied, and --undo moves the leftovers back"
}

test_a_home_without_a_board_gets_no_board() {
  local home root out
  home=$(tb_make_home no-board)
  root=$(make_code_root no-board-root)
  git -C "$ROOT" show "$BASE:fm-board/rules/captain.block.md.tmpl" > "$home/data/captain.md"
  out=$(mig "$home" "$root") || fail "the migration failed in a home without a board: $out"
  assert_contains "$out" "已搬完" "a home with only a rules block must finish"
  assert_contains "$(tb_run "$home" "$BOARD" rules)" "captain.md 和範本相同（v10）；captain-shared.md 未裝" \
    "only the file with an old block may be written"
  assert_absent "$home/state/myshape" "no board may start where none ran"
  assert_equals 0 "$(tb_board_count "$home")" "no board may start where none ran"
  pass "a home whose board never ran gets its rules block replaced and no board"
}

# bash 3.2 (the /bin/bash of macOS, where a second mate home runs the move)
# reads the bytes of a non-ASCII character that directly follows "$name" as
# part of the name. Linux cannot show that failure, so the shape is checked.
test_variables_are_braced_before_wide_characters() {
  local script hits
  for script in fm-board.sh fm-board-migrate-lib.sh fm-topic.sh fm-topic-session-start.sh; do
    hits=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$ROOT/bin/$script" || true)
    assert_equals "" "$hits" "$script: write \${name} when a non-ASCII character follows the variable"
  done
  pass "no variable in the move's scripts is directly followed by a non-ASCII character"
}

fm_test_run test_variables_are_braced_before_wide_characters test_moves_a_home_end_to_end test_undo_puts_everything_back test_undo_keeps_later_edits_outside_the_block \
  test_a_rerun_finishes_after_each_interruption test_a_changed_file_stops_the_move test_both_markers_and_a_broken_marker \
  test_refusals_change_nothing test_a_secondmate_home_only_tidies_the_checkout test_a_home_without_a_board_gets_no_board
