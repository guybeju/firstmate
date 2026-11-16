#!/usr/bin/env bash
# The page in a real browser: a headless Firefox walks the captain's path
# through the board (see stage-5-page.mjs) against stand-in firstmate scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"

for tool in jq node firefox; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
TMP_ROOT=$(fm_test_tmproot tb-s5p)
trap 'tb_stop_boards; fm_test_cleanup' EXIT

export FM_TOPIC_BOARD_TEST=1 FM_TOPIC_BOARD_LOCAL_MS=2000 FM_TOPIC_BOARD_REMOTE_MS=60000
export FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z
export TB_LOG="$TMP_ROOT/calls.log" TB_PLAY="$TMP_ROOT/play" TB_REMOTES="$TMP_ROOT/remotes"
mkdir -p "$TB_PLAY" "$TB_REMOTES"
: > "$TB_LOG"
CODE_ROOT="$TMP_ROOT/root"
tb_make_fake_root "$CODE_ROOT"
MAIN=$(tb_make_service_home main)

cat > "$TMP_ROOT/topic" <<EOF
#!/usr/bin/env bash
FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$CODE_ROOT" exec "$CODE_ROOT/bin/fm-topic.sh" "\$@"
EOF
chmod +x "$TMP_ROOT/topic"
export TB_TOPIC="$TMP_ROOT/topic"

"$TB_TOPIC" propose "Billing" --goal "rework billing" --id billing >/dev/null
"$TB_TOPIC" propose "Login" --goal "new login" --id login --queue high >/dev/null
"$TB_TOPIC" propose "Parked" --goal "later" --id parked --queue later >/dev/null
"$TB_TOPIC" propose "Idea" --goal "confirm me" --id idea >/dev/null
for id in billing login parked; do "$TB_TOPIC" confirm "$id" >/dev/null; done
cat > "$MAIN/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-a - Ship A (repo: sample) (kind: ship)

## Queued
- [ ] call-1 - A call (repo: sample) (kind: captain) (hold: 要合併嗎？ 選項：合併 | 先不要) (hold-kind: captain)
  Captain hold set: 2026-07-24T00:00:00Z

## Done
EOF
mkdir -p "$MAIN/projects/ship-a" "$MAIN/data/ship-a" "$MAIN/data/call-1"
fm_write_meta "$MAIN/state/ship-a.meta" "window=firstmate:fm-ship-a" "worktree=$MAIN/projects/ship-a" \
  "project=sample" "harness=claude" "kind=ship" "mode=ship" "yolo=off"
printf 'working: on it\n' > "$MAIN/state/ship-a.status"
# A second worker that was spawned and never wrote a status line.
mkdir -p "$MAIN/projects/quiet-b"
fm_write_meta "$MAIN/state/quiet-b.meta" "window=firstmate:fm-quiet-b" "worktree=$MAIN/projects/quiet-b" \
  "project=sample" "harness=claude" "kind=ship" "mode=ship" "yolo=off"
printf 'billing 2026-07-01T00:00:00Z\n' > "$MAIN/data/ship-a/topic"
printf 'billing 2026-07-01T00:00:00Z\n' > "$MAIN/data/call-1/topic"
mkdir -p "$MAIN/data/quiet-b"
printf 'parked 2026-07-01T00:00:00Z\n' > "$MAIN/data/quiet-b/topic"
: > "$MAIN/config/fleet-ledger"
printf 'PR 開好了，等你看。' | "$TB_TOPIC" summary ship-a ready - >/dev/null
"$TB_TOPIC" propose "Side idea" --goal "merge me" --id side >/dev/null

test_the_captains_path() {
  local url out
  url=$("$TB_TOPIC" open)
  out=$(node "$ROOT/topic-board/test/browser.mjs" "$url" "$ROOT/topic-board/test/stage-5-page.mjs" 2>&1) ||
    fail "the browser walk-through failed: $out"
  grep -q 'stdin=call-1	合併	合併	release' "$TB_LOG" || fail "the answer chosen in the page did not reach the hold"
  grep -q 'stdin=［議題：Billing X（billing）］\\n先做這個' "$TB_LOG" || fail "the message typed in the page did not reach firstmate"
  grep -q 'argv=ship-a|看一下 CI|' "$TB_LOG" || fail "the direct message typed in the page did not reach the agent"
  grep -q 'argv=ship-a|/compact|' "$TB_LOG" && fail "a command-like direct message reached the agent"
  assert_equals "login" "$(jq -r '.merged.side' "$MAIN/data/topics.json")" "the merge confirmed in the page did not happen"
  assert_equals "parked login" "$(jq -r '.queues.high | join(" ")' "$MAIN/data/topics.json")" "the drag did not reorder the queue"
  pass "the page works end to end in a real browser"
}

# profiles_of <pid>: the throwaway Firefox profiles a browser.mjs run owns.
profiles_of() {
  find "$HOME" -maxdepth 1 -name "tb-firefox-tmp-$1-*" 2>/dev/null
}

test_a_killed_run_leaves_no_profile_behind() {
  local url pid tries dead stale
  url=$("$TB_TOPIC" open)
  printf 'export default () => new Promise(() => {});\n' > "$TMP_ROOT/hang.mjs"
  node "$ROOT/topic-board/test/browser.mjs" "$url" "$TMP_ROOT/hang.mjs" >/dev/null 2>&1 &
  pid=$!
  for tries in $(seq 1 50); do
    [ -n "$(profiles_of "$pid")" ] && break
    sleep 0.1
  done
  [ -n "$(profiles_of "$pid")" ] || fail "the run never created its profile (after $tries tries)"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_equals "" "$(profiles_of "$pid")" "a terminated run must remove its Firefox profile"

  # A run killed outright cannot clean up; the next run removes what it left.
  sleep 0 &
  dead=$!
  wait "$dead"
  stale="$HOME/tb-firefox-tmp-$dead-stale"
  mkdir "$stale"
  printf 'export default () => {};\n' > "$TMP_ROOT/noop.mjs"
  node "$ROOT/topic-board/test/browser.mjs" "$url" "$TMP_ROOT/noop.mjs" >/dev/null 2>&1 ||
    { rmdir "$stale" 2>/dev/null; fail "the follow-up run failed"; }
  [ -e "$stale" ] && { rmdir "$stale"; fail "the next run must sweep a dead run's profile"; }
  pass "a killed browser run leaves no profile in the home directory"
}

fm_test_run test_the_captains_path test_a_killed_run_leaves_no_profile_behind
"$TB_TOPIC" stop >/dev/null
