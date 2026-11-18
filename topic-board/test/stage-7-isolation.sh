#!/usr/bin/env bash
# The board tree loads no Firstmate file and tells the dispatcher nothing (AT3
# of the board-interface test plan, as it stands for B1):
#   - a static scan of the board's own files for Firstmate script and data
#     names, each allowed only on a line pinned below by file and exact text;
#   - a run of stage-7-standalone.sh with tripwires named after every other
#     Firstmate script and library, which must leave the trip log empty, and
#     a check that those tripwires do fire;
#   - nothing in the command or its help that dictates what to dispatch.
# The board's unit tests (*.test.ts) are not scanned: the board never loads
# them, and they mirror the command table they test.
# shellcheck disable=SC2016 # jq filters and the pinned lines are literal text.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"
# shellcheck source=topic-board/test/standalone-lib.sh
. "$ROOT/topic-board/test/standalone-lib.sh"

for tool in jq node curl git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
TMP_ROOT=$(fm_test_tmproot tb-s7i)
case "$TMP_ROOT" in /*) ;; *) echo "not ok - no scratch root" >&2; exit 1 ;; esac
trap 'tb_stop_boards; fm_test_cleanup' EXIT

FIRSTMATE_NAMES='fm-[A-Za-z0-9_-]+\.sh|secondmates\.md|captain(-shared)?\.md|fleet-ledger|\.fm-secondmate-home|backlog\.md|fm-hold-v1'

# The board tree: its command, its library, and everything the service and the
# page load.
board_files() {
  (cd "$ROOT" && { printf '%s\n' bin/fm-topic.sh bin/fm-topic-lib.sh
    find topic-board/src topic-board/public topic-board/dist -type f ! -name '*.test.ts'; } | LC_ALL=C sort)
}

# scan: "<file>\t<line without leading blanks>" for every line of the board tree
# that names a Firstmate script or data file other than the board's own two.
scan() {
  local file hit line
  while IFS= read -r file; do
    while IFS= read -r hit; do
      line=${hit#*:}
      printf '%s' "$line" | sed -E 's/fm-topic(-lib)?\.sh//g' | grep -qE "$FIRSTMATE_NAMES" || continue
      printf '%s\t%s\n' "$file" "$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')"
    done <<< "$(cd "$ROOT" && grep -nE "$FIRSTMATE_NAMES" "$file" || true)"
  done <<< "$(board_files)"
}

# The lines allowed to name a Firstmate file in B1: the six old-form lines, the
# four calls todo add and todo done keep until the board stores hands-on items
# (design 4.2), the command table's rows and its comments, the ledger banner's
# commands, and comments that describe what those programs print.
pinned() {
  cat <<'PINS'
bin/fm-topic.sh	report=$("$SCRIPT_DIR/fm-topic-board-read.sh" 0 -) || tb_die 1 "讀不到這個 home 的 backlog，沒有改任何東西。"
bin/fm-topic.sh	"$SCRIPT_DIR/fm-captain-hold.sh" hold "${words[0]}" --title "${words[1]}" --reason "$text" \
bin/fm-topic.sh	"$SCRIPT_DIR/fm-board.sh" tag "${words[0]}" "$topic" >/dev/null ||
bin/fm-topic.sh	"$SCRIPT_DIR/fm-captain-hold.sh" answers --source topic-board) ||
bin/fm-topic.sh	tag) usage_error "沒有 tag 了：議題標記由 first mate 的指令寫，改用 bin/fm-board.sh tag <task-id> <議題 id>" ;;
bin/fm-topic.sh	--in-home) usage_error "沒有 --in-home 了：改用 bin/fm-board.sh --in-home <id> <tag|answers|setup> …" ;;
bin/fm-topic.sh	setup) usage_error "沒有 setup 了：改用 bin/fm-board.sh setup" ;;
bin/fm-topic.sh	install-rules) usage_error "沒有 install-rules 了：改用 bin/fm-board.sh install-rules" ;;
bin/fm-topic.sh	order) usage_error "沒有 order 了：改用 bin/fm-dispatch-plan.sh order" ;;
bin/fm-topic.sh	usage_error "split 只建議題；要一起搬 task，改用 bin/fm-board.sh split <議題 id> <新名稱> --goal <一行> <task…>"
topic-board/dist/actions.js	/** The close mode fm-captain-hold.sh answers takes for what answering `hold` does. */
topic-board/dist/commands.js	* Text handed to fm-send.sh as one argument. fm-send.sh treats a leading '-'
topic-board/dist/commands.js	/** One `<task-id>\t<answer>\t<label>\t<mode>` line for fm-captain-hold.sh answers. */
topic-board/dist/commands.js	const answers = ["fm-captain-hold.sh", "answers", "--source", "topic-board"];
topic-board/dist/commands.js	return { script: "fm-board.sh", args: ["--in-home", secondmate, "answers"], stdin };
topic-board/dist/commands.js	return { script: "fm-on.sh", args: ["--stdin", secondmate, ...answers], stdin };
topic-board/dist/commands.js	return { script: "fm-board.sh", args: tag };
topic-board/dist/commands.js	return { script: "fm-board.sh", args: ["--in-home", secondmate, ...tag] };
topic-board/dist/commands.js	return { script: "fm-on.sh", args: [secondmate, "fm-board.sh", ...tag] };
topic-board/dist/commands.js	script: "fm-send.sh",
topic-board/dist/commands.js	return { script: "fm-topic-board-read.sh", args: readArgs(command) };
topic-board/dist/commands.js	script: "fm-topic-board-read.sh",
topic-board/dist/commands.js	script: "fm-on.sh",
topic-board/dist/commands.js	"fm-topic-board-read.sh",
topic-board/dist/commands.js	script: "fm-inbox.sh",
topic-board/dist/commands.js	script: "fm-send.sh",
topic-board/dist/page/frame.js	return "bin/fm-board.sh setup";
topic-board/dist/page/frame.js	? `bin/fm-on.sh ${entry.id} fm-board.sh setup`
topic-board/dist/page/frame.js	: `bin/fm-board.sh --in-home ${entry.id} setup`;
topic-board/dist/poller.js	// fm-on.sh's refusals when the remote code root has no such tracked script.
topic-board/dist/report.js	// The JSON one home's fm-topic-board-read.sh prints, parsed and checked once
topic-board/dist/writes.js	/** Why fm-send.sh could not deliver, in words for the board; its own text when the cause is not known. */
topic-board/dist/writes.js	// fm-captain-hold.sh's reasons for skipping a hold that someone already answered or released.
topic-board/dist/writes.js	/** Reads fm-captain-hold.sh answers output for the line about `task`. */
topic-board/dist/writes.js	// Exit 3: fm-send.sh retried once and the remote delivery is still unconfirmed.
topic-board/src/actions.ts	/** The close mode fm-captain-hold.sh answers takes for what answering `hold` does. */
topic-board/src/commands.ts	* Text handed to fm-send.sh as one argument. fm-send.sh treats a leading '-'
topic-board/src/commands.ts	/** One `<task-id>\t<answer>\t<label>\t<mode>` line for fm-captain-hold.sh answers. */
topic-board/src/commands.ts	const answers = ["fm-captain-hold.sh", "answers", "--source", "topic-board"];
topic-board/src/commands.ts	return { script: "fm-board.sh", args: ["--in-home", secondmate, "answers"], stdin };
topic-board/src/commands.ts	return { script: "fm-on.sh", args: ["--stdin", secondmate, ...answers], stdin };
topic-board/src/commands.ts	return { script: "fm-board.sh", args: tag };
topic-board/src/commands.ts	return { script: "fm-board.sh", args: ["--in-home", secondmate, ...tag] };
topic-board/src/commands.ts	return { script: "fm-on.sh", args: [secondmate, "fm-board.sh", ...tag] };
topic-board/src/commands.ts	script: "fm-send.sh",
topic-board/src/commands.ts	return { script: "fm-topic-board-read.sh", args: readArgs(command) };
topic-board/src/commands.ts	script: "fm-topic-board-read.sh",
topic-board/src/commands.ts	script: "fm-on.sh",
topic-board/src/commands.ts	"fm-topic-board-read.sh",
topic-board/src/commands.ts	script: "fm-inbox.sh",
topic-board/src/commands.ts	script: "fm-send.sh",
topic-board/src/page/frame.ts	if (entry.id === "main") return "bin/fm-board.sh setup";
topic-board/src/page/frame.ts	? `bin/fm-on.sh ${entry.id} fm-board.sh setup`
topic-board/src/page/frame.ts	: `bin/fm-board.sh --in-home ${entry.id} setup`;
topic-board/src/poller.ts	// fm-on.sh's refusals when the remote code root has no such tracked script.
topic-board/src/report.ts	// The JSON one home's fm-topic-board-read.sh prints, parsed and checked once
topic-board/src/report.ts	/** What answering a hold does to its item, as `fm-captain-hold.sh hold --on-answer` recorded it. */
topic-board/src/writes.ts	/** Why fm-send.sh could not deliver, in words for the board; its own text when the cause is not known. */
topic-board/src/writes.ts	// fm-captain-hold.sh's reasons for skipping a hold that someone already answered or released.
topic-board/src/writes.ts	/** Reads fm-captain-hold.sh answers output for the line about `task`. */
topic-board/src/writes.ts	// Exit 3: fm-send.sh retried once and the remote delivery is still unconfirmed.
PINS
}

test_the_scan_finds_only_pinned_lines() {
  local found new gone
  found=$(scan | LC_ALL=C sort)
  new=$(LC_ALL=C comm -23 <(printf '%s\n' "$found") <(pinned | LC_ALL=C sort))
  gone=$(LC_ALL=C comm -13 <(printf '%s\n' "$found") <(pinned | LC_ALL=C sort))
  assert_equals "" "$new" "a line of the board tree names a Firstmate file without being pinned"
  assert_equals "" "$gone" "a pinned line is gone; update the pinned list"
  assert_equals '. "$SCRIPT_DIR/fm-topic-lib.sh"' "$(cd "$ROOT" && grep -E '^[[:space:]]*(\.|source)[[:space:]]+["$]' bin/fm-topic.sh)" \
    "fm-topic.sh must source only fm-topic-lib.sh"
  assert_equals "" "$(cd "$ROOT" && grep -E '^[[:space:]]*(\.|source)[[:space:]]+["$]' bin/fm-topic-lib.sh || true)" \
    "fm-topic-lib.sh must source nothing"
  pass "the board tree names Firstmate files only on the pinned lines, and its command sources only its own library"
}

# The scan must see a new name: plant one in a copy and look.
test_the_scan_catches_a_new_name() {
  local saved=$ROOT copy=$TMP_ROOT/scan-copy found
  mkdir -p "$copy/bin" "$copy/topic-board"
  (cd "$ROOT" && cp bin/fm-topic.sh bin/fm-topic-lib.sh "$copy/bin/")
  cp -R "$ROOT/topic-board/src" "$ROOT/topic-board/public" "$ROOT/topic-board/dist" "$copy/topic-board/"
  printf '%s\n' '  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json' >> "$copy/bin/fm-topic.sh"
  printf '%s\n' 'const registry = "data/secondmates.md";' >> "$copy/topic-board/src/poller.ts"
  ROOT=$copy
  found=$(scan | LC_ALL=C sort | LC_ALL=C comm -23 - <(pinned | LC_ALL=C sort))
  ROOT=$saved
  assert_contains "$found" "$(printf 'bin/fm-topic.sh\t"$SCRIPT_DIR/fm-fleet-snapshot.sh" --json')" "the scan must report a new script call"
  assert_contains "$found" "$(printf 'topic-board/src/poller.ts\tconst registry = "data/secondmates.md";')" "the scan must report a new data name"
  pass "the scan reports a new Firstmate script or data name"
}

test_the_board_trips_no_wire() {
  local out rc=0
  out=$(TB_STAGE7_TRIPWIRES=1 "${BASH:-bash}" "$ROOT/topic-board/test/stage-7-standalone.sh" 2>&1) || rc=$?
  assert_equals 0 "$rc" "the board alone must pass with tripwires around it: $out"
  assert_contains "$out" "ok - no board is left running and no Firstmate file was reached" "the tripwire run must check its log"
  pass "the board's command and service run beside tripwires for every other Firstmate file and trip none"
}

# The tripwires must fire: a board-only root whose command sources a Firstmate
# library and runs a Firstmate script through PATH trips both.
test_the_tripwires_fire() {
  local home
  sa_init
  SA_ROOT=$TMP_ROOT/trip/board
  mkdir -p "$TMP_ROOT/trip"
  tb_make_board_root "$SA_ROOT" >/dev/null
  sa_trip_root "$SA_ROOT"
  sed -i.bak 's|^\. "\$SCRIPT_DIR/fm-topic-lib.sh"$|&\n. "$SCRIPT_DIR/fm-primary-scope-lib.sh"\nfm-fleet-snapshot.sh --json >/dev/null 2>\&1 \|\| true|' \
    "$SA_ROOT/bin/fm-topic.sh"
  home=$(sa_home trip-home)
  sa "$home" --help >/dev/null 2>&1 || true
  assert_grep 'sourced fm-primary-scope-lib.sh' "$SA_TRIP_LOG" "a sourced Firstmate library must trip its wire"
  assert_grep 'ran fm-fleet-snapshot.sh --json' "$SA_TRIP_LOG" "a Firstmate script found through PATH must trip its wire"
  pass "the tripwires catch a sourced library and a script found through PATH"
}

test_nothing_dictates_the_dispatcher() {
  local out
  assert_equals "" "$(cd "$ROOT" && board_files | xargs grep -nE 'fm-tasks-axi|fm-spawn|unhold|--reason "topic-board：' || true)" \
    "the board tree must not name the dispatcher's commands"
  assert_equals "order) usage_error \"沒有 order 了：改用 bin/fm-dispatch-plan.sh order\" ;;" \
    "$(cd "$ROOT" && grep -E '^[[:space:]]*order\)' bin/fm-topic.sh | sed -E 's/^[[:space:]]+//')" \
    "order may appear in the command only as its old form"
  # The tripwire test above left a board-only root and a home behind.
  out=$(sa "$TMP_ROOT/trip-home" --help)
  assert_equals "" "$(printf '%s\n' "$out" | grep -E '^  fm-topic\.sh (order|hold|unhold|dispatch)' || true)" \
    "--help must list no dispatch subcommand"
  assert_not_contains "$out" "fm-dispatch-plan" "--help must name no dispatch command"
  assert_not_contains "$out" "fm-tasks-axi" "--help must name no backlog command"
  pass "nothing in the board's command or help dictates what to dispatch"
}

fm_test_run test_the_scan_finds_only_pinned_lines test_the_scan_catches_a_new_name test_the_board_trips_no_wire \
  test_the_tripwires_fire test_nothing_dictates_the_dispatcher
