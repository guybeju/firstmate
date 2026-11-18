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
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"
# shellcheck source=myshape/test/standalone-lib.sh
. "$ROOT/myshape/test/standalone-lib.sh"

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
  (cd "$ROOT" && { printf '%s\n' bin/myshape.sh bin/myshape-lib.sh
    find myshape/src myshape/public myshape/dist -type f ! -name '*.test.ts'; } | LC_ALL=C sort)
}

# scan: "<file>\t<line without leading blanks>" for every line of the board tree
# that names a Firstmate script or data file other than the board's own two.
scan() {
  local file hit line
  while IFS= read -r file; do
    while IFS= read -r hit; do
      line=${hit#*:}
      printf '%s' "$line" | grep -qE "$FIRSTMATE_NAMES" || continue
      printf '%s\t%s\n' "$file" "$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')"
    done <<< "$(cd "$ROOT" && grep -nE "$FIRSTMATE_NAMES" "$file" || true)"
  done <<< "$(board_files)"
}

# The lines allowed to name a Firstmate file: the old-path refusal, which names
# Firstmate's move to the new names until that move is gone; the split line
# naming the command that moves tasks; the four calls todo add and todo done
# keep until the board stores hands-on items (design 4.2); the command table's
# rows and its comments; the ledger banner's commands; and comments that
# describe what those programs print.
pinned() {
  cat <<'PINS'
bin/myshape.sh	report=$("$SCRIPT_DIR/fm-topic-board-read.sh" 0 -) || tb_die 1 "讀不到這個 home 的 backlog，沒有改任何東西。"
bin/myshape.sh	"$SCRIPT_DIR/fm-captain-hold.sh" hold "${words[0]}" --title "${words[1]}" --reason "$text" \
bin/myshape.sh	"$SCRIPT_DIR/fm-board.sh" tag "${words[0]}" "$topic" >/dev/null ||
bin/myshape.sh	"$SCRIPT_DIR/fm-captain-hold.sh" answers --source myshape) ||
bin/myshape.sh	service_unavailable "這個 home 還有改名前的 $1" "先跑 bin/fm-board.sh migrate-myshape 搬到新名字"
bin/myshape.sh	usage_error "split 只建議題；要一起搬 task，改用 bin/fm-board.sh split <議題 id> <新名稱> --goal <一行> <task…>"
myshape/dist/actions.js	/** The close mode fm-captain-hold.sh answers takes for what answering `hold` does. */
myshape/dist/commands.js	* Text handed to fm-send.sh as one argument. fm-send.sh treats a leading '-'
myshape/dist/commands.js	/** One `<task-id>\t<answer>\t<label>\t<mode>` line for fm-captain-hold.sh answers. */
myshape/dist/commands.js	const answers = ["fm-captain-hold.sh", "answers", "--source", "myshape"];
myshape/dist/commands.js	return { script: "fm-board.sh", args: ["--in-home", secondmate, "answers"], stdin };
myshape/dist/commands.js	return { script: "fm-on.sh", args: ["--stdin", secondmate, ...answers], stdin };
myshape/dist/commands.js	return { script: "fm-board.sh", args: tag };
myshape/dist/commands.js	return { script: "fm-board.sh", args: ["--in-home", secondmate, ...tag] };
myshape/dist/commands.js	return { script: "fm-on.sh", args: [secondmate, "fm-board.sh", ...tag] };
myshape/dist/commands.js	script: "fm-send.sh",
myshape/dist/commands.js	return { script: "fm-topic-board-read.sh", args: readArgs(command) };
myshape/dist/commands.js	script: "fm-topic-board-read.sh",
myshape/dist/commands.js	script: "fm-on.sh",
myshape/dist/commands.js	"fm-topic-board-read.sh",
myshape/dist/commands.js	script: "fm-inbox.sh",
myshape/dist/commands.js	script: "fm-send.sh",
myshape/dist/page/frame.js	return "bin/fm-board.sh setup";
myshape/dist/page/frame.js	? `bin/fm-on.sh ${entry.id} fm-board.sh setup`
myshape/dist/page/frame.js	: `bin/fm-board.sh --in-home ${entry.id} setup`;
myshape/dist/poller.js	// fm-on.sh's refusals when the remote code root has no such tracked script.
myshape/dist/report.js	// The JSON one home's fm-topic-board-read.sh prints, parsed and checked once
myshape/dist/writes.js	/** Why fm-send.sh could not deliver, in words for the board; its own text when the cause is not known. */
myshape/dist/writes.js	// fm-captain-hold.sh's reasons for skipping a hold that someone already answered or released.
myshape/dist/writes.js	/** Reads fm-captain-hold.sh answers output for the line about `task`. */
myshape/dist/writes.js	// Exit 3: fm-send.sh retried once and the remote delivery is still unconfirmed.
myshape/src/actions.ts	/** The close mode fm-captain-hold.sh answers takes for what answering `hold` does. */
myshape/src/commands.ts	* Text handed to fm-send.sh as one argument. fm-send.sh treats a leading '-'
myshape/src/commands.ts	/** One `<task-id>\t<answer>\t<label>\t<mode>` line for fm-captain-hold.sh answers. */
myshape/src/commands.ts	const answers = ["fm-captain-hold.sh", "answers", "--source", "myshape"];
myshape/src/commands.ts	return { script: "fm-board.sh", args: ["--in-home", secondmate, "answers"], stdin };
myshape/src/commands.ts	return { script: "fm-on.sh", args: ["--stdin", secondmate, ...answers], stdin };
myshape/src/commands.ts	return { script: "fm-board.sh", args: tag };
myshape/src/commands.ts	return { script: "fm-board.sh", args: ["--in-home", secondmate, ...tag] };
myshape/src/commands.ts	return { script: "fm-on.sh", args: [secondmate, "fm-board.sh", ...tag] };
myshape/src/commands.ts	script: "fm-send.sh",
myshape/src/commands.ts	return { script: "fm-topic-board-read.sh", args: readArgs(command) };
myshape/src/commands.ts	script: "fm-topic-board-read.sh",
myshape/src/commands.ts	script: "fm-on.sh",
myshape/src/commands.ts	"fm-topic-board-read.sh",
myshape/src/commands.ts	script: "fm-inbox.sh",
myshape/src/commands.ts	script: "fm-send.sh",
myshape/src/page/frame.ts	if (entry.id === "main") return "bin/fm-board.sh setup";
myshape/src/page/frame.ts	? `bin/fm-on.sh ${entry.id} fm-board.sh setup`
myshape/src/page/frame.ts	: `bin/fm-board.sh --in-home ${entry.id} setup`;
myshape/src/poller.ts	// fm-on.sh's refusals when the remote code root has no such tracked script.
myshape/src/report.ts	// The JSON one home's fm-topic-board-read.sh prints, parsed and checked once
myshape/src/report.ts	/** What answering a hold does to its item, as `fm-captain-hold.sh hold --on-answer` recorded it. */
myshape/src/writes.ts	/** Why fm-send.sh could not deliver, in words for the board; its own text when the cause is not known. */
myshape/src/writes.ts	// fm-captain-hold.sh's reasons for skipping a hold that someone already answered or released.
myshape/src/writes.ts	/** Reads fm-captain-hold.sh answers output for the line about `task`. */
myshape/src/writes.ts	// Exit 3: fm-send.sh retried once and the remote delivery is still unconfirmed.
PINS
}

test_the_scan_finds_only_pinned_lines() {
  local found new gone
  found=$(scan | LC_ALL=C sort)
  new=$(LC_ALL=C comm -23 <(printf '%s\n' "$found") <(pinned | LC_ALL=C sort))
  gone=$(LC_ALL=C comm -13 <(printf '%s\n' "$found") <(pinned | LC_ALL=C sort))
  assert_equals "" "$new" "a line of the board tree names a Firstmate file without being pinned"
  assert_equals "" "$gone" "a pinned line is gone; update the pinned list"
  assert_equals '. "$SCRIPT_DIR/myshape-lib.sh"' "$(cd "$ROOT" && grep -E '^[[:space:]]*(\.|source)[[:space:]]+["$]' bin/myshape.sh)" \
    "myshape.sh must source only myshape-lib.sh"
  assert_equals "" "$(cd "$ROOT" && grep -E '^[[:space:]]*(\.|source)[[:space:]]+["$]' bin/myshape-lib.sh || true)" \
    "myshape-lib.sh must source nothing"
  pass "the board tree names Firstmate files only on the pinned lines, and its command sources only its own library"
}

# The scan must see a new name: plant one in a copy and look.
test_the_scan_catches_a_new_name() {
  local saved=$ROOT copy=$TMP_ROOT/scan-copy found
  mkdir -p "$copy/bin" "$copy/myshape"
  (cd "$ROOT" && cp bin/myshape.sh bin/myshape-lib.sh "$copy/bin/")
  cp -R "$ROOT/myshape/src" "$ROOT/myshape/public" "$ROOT/myshape/dist" "$copy/myshape/"
  printf '%s\n' '  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json' >> "$copy/bin/myshape.sh"
  printf '%s\n' 'const registry = "data/secondmates.md";' >> "$copy/myshape/src/poller.ts"
  ROOT=$copy
  found=$(scan | LC_ALL=C sort | LC_ALL=C comm -23 - <(pinned | LC_ALL=C sort))
  ROOT=$saved
  assert_contains "$found" "$(printf 'bin/myshape.sh\t"$SCRIPT_DIR/fm-fleet-snapshot.sh" --json')" "the scan must report a new script call"
  assert_contains "$found" "$(printf 'myshape/src/poller.ts\tconst registry = "data/secondmates.md";')" "the scan must report a new data name"
  pass "the scan reports a new Firstmate script or data name"
}

test_the_board_trips_no_wire() {
  local out rc=0
  out=$(TB_STAGE7_TRIPWIRES=1 "${BASH:-bash}" "$ROOT/myshape/test/stage-7-standalone.sh" 2>&1) || rc=$?
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
  sed -i.bak 's|^\. "\$SCRIPT_DIR/myshape-lib.sh"$|&\n. "$SCRIPT_DIR/fm-primary-scope-lib.sh"\nfm-fleet-snapshot.sh --json >/dev/null 2>\&1 \|\| true|' \
    "$SA_ROOT/bin/myshape.sh"
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
  assert_equals "" "$(cd "$ROOT" && grep -nE '(^|[^a-z-])order\)' bin/myshape.sh || true)" \
    "order must not be a subcommand of the board's command"
  # The tripwire test above left a board-only root and a home behind.
  out=$(sa "$TMP_ROOT/trip-home" --help)
  assert_equals "" "$(printf '%s\n' "$out" | grep -E '^  myshape\.sh (order|hold|unhold|dispatch)' || true)" \
    "--help must list no dispatch subcommand"
  assert_not_contains "$out" "fm-dispatch-plan" "--help must name no dispatch command"
  assert_not_contains "$out" "fm-tasks-axi" "--help must name no backlog command"
  pass "nothing in the board's command or help dictates what to dispatch"
}

fm_test_run test_the_scan_finds_only_pinned_lines test_the_scan_catches_a_new_name test_the_board_trips_no_wire \
  test_the_tripwires_fire test_nothing_dictates_the_dispatcher
