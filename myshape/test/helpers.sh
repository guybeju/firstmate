#!/usr/bin/env bash
# Shared fixtures for the myshape tests. Sourced after tests/lib.sh.
# shellcheck disable=SC2034 # the path globals are read by the sourcing tests.

# The board refuses a socket path longer than the platform allows (103 bytes
# on macOS), and macOS's default temp directory is deep enough to exceed it.
# Scratch homes go under /tmp when the default base is that long.
tmpdir_default=${TMPDIR:-}
if [ "${#tmpdir_default}" -gt 40 ]; then
  export TMPDIR=/tmp
fi
unset tmpdir_default

TOPIC="$ROOT/bin/myshape.sh"
BOARD_READ="$ROOT/bin/fm-topic-board-read.sh"
BOARD="$ROOT/bin/fm-board.sh"

# tb_make_home <name>: create an empty main home under TMP_ROOT and print it.
tb_make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

# tb_board_has_run <home>: give <home> the token the board service writes the
# first time it starts, so myshape.sh treats it as a home whose board has run.
tb_board_has_run() {
  mkdir -p "$1/state/myshape"
  printf '%064d\n' 0 > "$1/state/myshape/token"
  chmod 600 "$1/state/myshape/token"
}

# tb_make_secondmate_home <name> <id>: like tb_make_home plus the marker file
# upstream uses to recognize a secondmate home.
tb_make_secondmate_home() {
  local home
  home=$(tb_make_home "$1")
  printf '%s\n' "$2" > "$home/.fm-secondmate-home"
  printf '%s\n' "$home"
}

# tb_write_topics <home>: two queued topics, one parked, one merged alias, one
# archived topic, and one proposal left by board code from before every topic
# was confirmed at once (the board confirms it the next time it starts).
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

# tb_seed_unstarted <code-root> <task>: make <code-root>'s snapshot report <task>
# the way upstream does for a harness that has not taken its first turn since
# spawn (the busy record is still fm-spawn's seed). A real one needs a live pane.
tb_seed_unstarted() {
  rm -f "$1/bin/fm-fleet-snapshot.sh"
  cat > "$1/bin/fm-fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
"$ROOT/bin/fm-fleet-snapshot.sh" "\$@" | jq -c --arg task "$2" '
  (.tasks[] | select(.id == \$task) | .current_state) =
    {state: "working", source: "pane", detail: "harness busy (fm-spawn)", freshness: "fresh"}'
SH
  chmod +x "$1/bin/fm-fleet-snapshot.sh"
}

# --- board service fixtures ---------------------------------------------------

# tb_free_port: print a TCP port nothing is listening on right now.
tb_free_port() {
  node -e 'const s = require("node:net").createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });'
}

# tb_make_service_home <name>: a main home with its own board port.
tb_make_service_home() {
  local home
  home=$(tb_make_home "$1")
  tb_free_port > "$home/config/myshape-port"
  printf '%s\n' "$home"
}

# tb_board_pid <home>: the pid the running board recorded, or nothing.
tb_board_pid() {
  cat "$1/state/myshape/pid" 2>/dev/null || true
}

# tb_board_count <home>: how many board-server processes serve <home>.
tb_board_count() {
  pgrep -f "board-server.js.*--state $1/state" | wc -l | tr -d ' '
}

# tb_stop_boards: stop every board started under TMP_ROOT through its own
# socket, which sends no signal. Registered on EXIT so a failed assertion never
# leaves a service behind. It does nothing unless TMP_ROOT is an absolute path
# below /, so a scratch root that failed to be made cannot widen the match to
# another home's board. A board still running five seconds after its stop is
# reported as a failure; fm_test_cleanup then runs and the script exits 1. In a
# signal dry run (myshape/test/signal-lib.sh) each board found is also logged
# with its ancestry.
tb_stop_boards() {
  local pid state pids i=0
  case "${TMP_ROOT:-}" in /?*) ;; *) return 0 ;; esac
  for pid in $(tb_boards_under "$TMP_ROOT"); do
    [ -z "${SIGNAL_CHECK:-}" ] || [ -z "${FM_TEST_SIGNAL_LOG:-}" ] ||
      "$SIGNAL_CHECK" "$$" "$FM_TEST_SIGNAL_LOG" tb_stop_boards "$pid" >/dev/null
    state=$(ps -ww -o args= -p "$pid" | sed -n 's/.*--state \([^ ]*\).*/\1/p')
    [ -z "$state" ] || tb_socket_stop "$state/myshape/board.sock"
  done
  pids=$(tb_boards_under "$TMP_ROOT")
  while [ -n "$pids" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
    pids=$(tb_boards_under "$TMP_ROOT")
  done
  [ -z "$pids" ] && return 0
  # shellcheck disable=SC2086 # one word per pid.
  printf 'not ok - a board under %s did not stop through its socket: %s\n' "$TMP_ROOT" "$(printf '%s ' $pids)" >&2
  fm_test_cleanup
  exit 1
}

# tb_boards_under <root>: the pids of the board services whose state is under
# <root>, found by command line; nothing is signalled.
tb_boards_under() {
  pgrep -f "board-server.js.*--state $1/" || true
}

# tb_socket_stop <socket>: ask the board on <socket> to stop, which it does by
# exiting; no signal is sent. Quiet when nothing answers.
tb_socket_stop() {
  node -e '
    const connection = require("node:net").connect(process.argv[1]);
    connection.on("connect", () => connection.write(JSON.stringify({ v: 1, op: "stop", args: {} }) + "\n"));
    connection.on("data", () => connection.end());
    connection.on("error", () => process.exit(0));
  ' "$1" 2>/dev/null || true
}

# tb_listeners <port>: every local address something listens on at that TCP
# port, one "<address>:<port>" per line, sorted and without repeats. Linux has
# ss; macOS has lsof.
tb_listeners() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH | awk -v suffix=":$1" 'substr($4, length($4) - length(suffix) + 1) == suffix { print $4 }'
  else
    lsof -nP -iTCP:"$1" -sTCP:LISTEN | awk 'NR > 1 { print $9 }'
  fi | sort -u
}

# tb_mode <path>: the ls-style type and permission string, e.g. "-rw-------".
tb_mode() {
  stat -c '%A' "$1" 2>/dev/null || stat -f '%Sp' "$1"
}

# tb_op <home> <op> [json-args]: send one raw request to the board's socket and
# print the response's "data" member. For ops myshape.sh does not expose.
tb_op() {
  # Not "${3:-{\}}": bash versions disagree on whether that backslash is kept.
  local args=${3:-}
  [ -n "$args" ] || args='{}'
  node -e '
    const [socket, op, args] = process.argv.slice(1);
    const connection = require("node:net").connect(socket);
    let received = "";
    connection.on("connect", () => connection.write(JSON.stringify({ v: 1, op, args: JSON.parse(args) }) + "\n"));
    connection.on("data", (chunk) => { received += chunk; });
    connection.on("end", () => {
      const response = JSON.parse(received);
      if (!response.ok) { console.error(response.line); process.exit(1); }
      console.log(JSON.stringify(response.data ?? {}));
    });
    connection.on("error", (error) => { console.error(error.message); process.exit(1); });
  ' "$1/state/myshape/board.sock" "$2" "$args"
}

# tb_make_fake_root <dir>: a private code root with this checkout's scripts and
# build, its own git history, stand-ins for the four scripts the board writes
# through (fm-inbox.sh, fm-send.sh, fm-captain-hold.sh, fm-on.sh), and the
# committed bin/fm-board.sh wrapper of tb_fake_aggregator. A home's board runs
# it once the home is bound (tb_bind_home).
#
# Each stand-in appends "cmd=<key>\targv=<a|b|...>\thome=<FM_HOME>\tstdin=<text>"
# to $TB_LOG, then follows the next step in $TB_PLAY/<key> when there is one. A
# step is "<exit code or sleepN>\t<stdout>". "Remote" home <id> is the local
# directory $TB_REMOTES/<id>.
tb_make_fake_root() {
  local fake=$1 name
  fm_git_init_commit "$fake"
  mkdir -p "$fake/bin" "$fake/myshape"
  ln -s "$ROOT"/bin/* "$fake/bin/"
  ln -s "$ROOT/myshape/dist" "$fake/myshape/dist"
  rm "$fake/bin/fm-on.sh" "$fake/bin/fm-inbox.sh" "$fake/bin/fm-send.sh" "$fake/bin/fm-captain-hold.sh"
  cat > "$fake/bin/tb-fake-lib.sh" <<'SH'
tb_fake() {  # <play key> <stdin> <argv...>
  local key=$1 input=$2 step code out play
  shift 2
  {
    printf 'cmd=%s\targv=' "$key"
    printf '%s|' "$@"
    printf '\thome=%s\tstdin=%s\n' "${FM_HOME:-}" "${input//$'\n'/\\n}"
  } >> "$TB_LOG"
  play="$TB_PLAY/$key"
  [ -s "$play" ] || return 0
  IFS= read -r step < "$play"
  tail -n +2 "$play" > "$play.next"
  mv "$play.next" "$play"
  code=${step%%$'\t'*}
  out=${step#*$'\t'}
  [ "$out" = "$step" ] || printf '%s\n' "$out"
  case "$code" in
    sleep*)
      printf 'start %s\n' "$key" >> "$TB_LOG"
      sleep "${code#sleep}"
      printf 'end %s\n' "$key" >> "$TB_LOG"
      code=0
      ;;
  esac
  exit "$code"
}
SH
  for name in fm-inbox.sh fm-send.sh; do
    cat > "$fake/bin/$name" <<'SH'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/tb-fake-lib.sh"
tb_fake "$(basename "$0")" "$(cat)" "$@"
exit 0
SH
  done
  cat > "$fake/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/tb-fake-lib.sh"
input=$(cat)
tb_fake fm-captain-hold.sh "$input" "$@"
printf 'closed: %s\n' "${input%%$'\t'*}"
SH
  cat > "$fake/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/tb-fake-lib.sh"
[ "$1" != --stdin ] || shift
id=$1
script=$2
shift 2
case "$script" in
  fm-remote-file.sh) exit 1 ;;
  fm-topic-board-read.sh) FM_HOME="$TB_REMOTES/$id" exec "$(dirname "$0")/$script" "$@" ;;
esac
input=$(cat)
tb_fake "fm-on.sh.$script" "$input" "$id" "$@"
case "$script" in
  fm-board.sh) FM_HOME="$TB_REMOTES/$id" exec "$(dirname "$0")/$script" "$@" ;;
  fm-captain-hold.sh) printf 'closed: %s\n' "${input%%$'\t'*}" ;;
esac
SH
  chmod +x "$fake"/bin/fm-on.sh "$fake"/bin/fm-inbox.sh "$fake"/bin/fm-send.sh "$fake"/bin/fm-captain-hold.sh
  tb_fake_aggregator "$fake"
}

# The settings the stand-ins and the reader take from the environment of the
# test that made the root. The board hands its programs a fixed, short
# environment (contracts section 7), so they reach bin/fm-board.sh through
# <root>/tb-fake.env instead.
TB_FAKE_ENV_NAMES="TB_LOG TB_PLAY TB_REMOTES FM_SNAPSHOT_NOW"

# tb_fake_aggregator <fake-root>: make that root's bin/fm-board.sh the program the
# board's binding names: a committed wrapper (git tracks it unchanged, so it
# runs without a confirmation) that loads <root>/tb-fake.env and runs this
# checkout's fm-board.sh from <root>/bin, beside the stand-ins. Run it after
# the test exported the settings of TB_FAKE_ENV_NAMES it needs.
tb_fake_aggregator() {
  local fake=$1 name
  : > "$fake/tb-fake.env"
  for name in $TB_FAKE_ENV_NAMES; do
    [ -z "${!name+x}" ] || printf 'export %s=%q\n' "$name" "${!name}" >> "$fake/tb-fake.env"
  done
  rm -f "$fake/bin/fm-board.sh"
  ln -s "$ROOT/bin/fm-board.sh" "$fake/bin/fm-board-real.sh"
  cat > "$fake/bin/fm-board.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$(dirname "$0")/../tb-fake.env"
exec "$(dirname "$0")/fm-board-real.sh" "$@"
SH
  chmod 755 "$fake/bin/fm-board.sh"
  git -C "$fake" add bin/fm-board.sh
  git -C "$fake" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "fake aggregator"
}

# tb_bind_home <home>: bind the home's board to firstmate's programs, the way
# bin/fm-board.sh bind does.
tb_bind_home() {
  printf '%s\n' '{"v":1,"name":"firstmate","feed":"bin/fm-board.sh","deliver":"bin/fm-board.sh"}' \
    > "$1/config/myshape-aggregator.json"
  chmod 644 "$1/config/myshape-aggregator.json"
}

# --- board-only root ------------------------------------------------------------

# The files a board-only root holds: the board's command and library, its
# build, its page, and package.json (an install has it, and an older node 22
# needs it to load dist/ as modules).
TB_BOARD_FILES="bin/myshape.sh bin/myshape-lib.sh myshape/dist myshape/public myshape/package.json"

# tb_make_board_root <dir> [<rev> [<files>]]: a copy, not symlinks, of exactly
# the board's files (TB_BOARD_FILES, or the space-separated <files>), from this
# working tree or, with <rev>, from that commit of this checkout; then a git
# repository holding them as its one commit. The service finds its page next
# to its own running file, so a symlinked root would serve this checkout's page.
tb_make_board_root() {
  local dir=$1 rev=${2:-} files=${3:-$TB_BOARD_FILES} path
  mkdir -p "$dir"
  if [ -n "$rev" ]; then
    # shellcheck disable=SC2086 # the file list is a list of words.
    git -C "$ROOT" archive "$rev" $files | tar -x -C "$dir"
  else
    for path in $files; do
      mkdir -p "$dir/$(dirname "$path")"
      cp -R "$ROOT/$path" "$dir/$path"
    done
  fi
  tb_commit_root "$dir" "board-only root"
}

# tb_commit_root <dir> <message>: commit everything in <dir> (making it a git
# repository first when it is not one) and print the new commit.
tb_commit_root() {
  [ -d "$1/.git" ] || git -C "$1" init -q -b main
  git -C "$1" add -A
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
  git -C "$1" rev-parse HEAD
}
