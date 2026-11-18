#!/usr/bin/env bash
# The hardened environment every stage-7 script runs the board in (AT0 of the
# board-interface test plan). Sourced after tests/lib.sh and helpers.sh, once
# TMP_ROOT is set. It runs the board from a board-only root (tb_make_board_root)
# with:
#   - a clean environment: env -i with only HOME, PATH, LANG, TMPDIR, FM_HOME
#     and the test's own timing variables, so no FM_*_OVERRIDE and no real
#     FM_HOME the caller has can steer the board;
#   - a system-only PATH: a tripwire directory, /usr/bin, /bin, and the
#     directories of node, jq and git when they live elsewhere;
#   - tripwires named after every Firstmate script and library of this
#     checkout, which log to $SA_TRIP_LOG when run or sourced;
#   - decoy Firstmate files in every scratch home, checked byte for byte at
#     the end.
# shellcheck disable=SC2034 # the globals are read by the sourcing scripts.

# The programs this build of the board is still designed to run (design 7.1,
# B1): absent from every board-only root instead of tripwired, so running one
# fails with ENOENT.
SA_NO_TRIPWIRE="fm-topic-board-read.sh fm-on.sh fm-inbox.sh fm-send.sh fm-captain-hold.sh fm-board.sh"
# The board's own two files, which a board-only root holds for real.
SA_OWN="fm-topic.sh fm-topic-lib.sh"
LIVE_BOARD_PORT=47819

# sa_init: build the PATH, the tripwire directory, and the trip log. Stops the
# script when TMP_ROOT is unset or a PATH directory holds a Firstmate script.
sa_init() {
  local dir tool
  local -a dirs
  case "${TMP_ROOT:-}" in
    /*) ;;
    *) fail "TMP_ROOT must be an absolute scratch directory before sa_init" ;;
  esac
  SA_TRIP_LOG=$TMP_ROOT/tripwire.log
  : > "$SA_TRIP_LOG"
  SA_PATHTRIP=$TMP_ROOT/pathtrip
  mkdir -p "$SA_PATHTRIP" "$TMP_ROOT/h" "$TMP_ROOT/tmp"
  SA_TMPDIR=$TMP_ROOT/tmp
  SA_PATH="$SA_PATHTRIP:/usr/bin:/bin"
  for tool in node jq git; do
    dir=$(dirname "$(command -v "$tool")")
    case ":$SA_PATH:" in *":$dir:"*) ;; *) SA_PATH="$SA_PATH:$dir" ;; esac
  done
  IFS=: read -r -a dirs <<< "${SA_PATH#"$SA_PATHTRIP":}"
  for dir in "${dirs[@]}"; do
    if compgen -G "$dir/fm-*" >/dev/null; then
      fail "PATH directory $dir holds a file named fm-*; the board could find a Firstmate script there"
    fi
  done
  sa_tripwires "$SA_PATHTRIP" all
}

# sa_tripwires <dir> <all|others>: one tripwire per Firstmate script name of
# this checkout in <dir>: every name but the no-tripwire ones, and with
# "others" also not the board's own two files. A *-lib.sh tripwire logs when
# sourced; any other logs when run and exits 97.
sa_tripwires() {
  local dir=$1 which=$2 path name
  mkdir -p "$dir"
  for path in "$ROOT"/bin/fm-*.sh; do
    name=${path##*/}
    case " $SA_NO_TRIPWIRE " in *" $name "*) continue ;; esac
    if [ "$which" = others ]; then
      case " $SA_OWN " in *" $name "*) continue ;; esac
    fi
    case "$name" in
      *-lib.sh) printf 'printf "sourced %%s\\n" %q >> %q\n' "$name" "$SA_TRIP_LOG" > "$dir/$name" ;;
      *) printf '#!/bin/sh\nprintf "ran %%s %%s\\n" %q "$*" >> %q\nexit 97\n' "$name" "$SA_TRIP_LOG" > "$dir/$name" ;;
    esac
    chmod +x "$dir/$name"
  done
}

# sa_trip_root <broot>: tripwires in the root's bin/ and in a bin/ beside the
# root, for every Firstmate name the root does not hold for real.
sa_trip_root() {
  sa_tripwires "$1/bin" others
  sa_tripwires "$(dirname "$1")/bin" all
}

# sa_home <name>: a scratch home under TMP_ROOT with its own free port. Stops
# the script if the home is outside the scratch root or the port is the live
# board's.
sa_home() {
  local home=$TMP_ROOT/$1 port
  mkdir -p "$home/state" "$home/data" "$home/config"
  port=$(tb_free_port)
  printf '%s\n' "$port" > "$home/config/topic-board-port"
  sa_assert_scratch "$home"
  printf '%s\n' "$home"
}

sa_assert_scratch() {  # <home>
  local port
  case "$1/" in
    "$TMP_ROOT"/*) ;;
    *) fail "home $1 is outside the scratch root $TMP_ROOT" ;;
  esac
  port=$(cat "$1/config/topic-board-port" 2>/dev/null || true)
  case "$port" in
    '' | "$LIVE_BOARD_PORT") fail "home $1 must have its own port, never $LIVE_BOARD_PORT" ;;
  esac
}

# The decoys of AT0.4, relative to a home.
SA_DECOYS="data/captain.md data/captain-shared.md data/secondmates.md config/fleet-ledger state/fleet-ledger.jsonl .fm-secondmate-home data/backlog.md"

# sa_decoys <home>: Firstmate's files, as a Firstmate home would hold them,
# with their checksums recorded beside the home.
sa_decoys() {
  local home=$1
  printf '%s\n' '<!-- topic-board:begin v9（裝好的規則） -->' '- 規則' '<!-- topic-board:end -->' > "$home/data/captain.md"
  printf '%s\n' '# Shared captain preferences' '<!-- topic-board:begin v3（裝好的規則） -->' '- 共用' \
    '<!-- topic-board:end -->' > "$home/data/captain-shared.md"
  cat > "$home/data/secondmates.md" <<EOF
# Secondmates
- sm1 - Local helper (home: $TMP_ROOT/sm1; scope: sample work; projects: alpha; added 2026-11-01)
- far1 - Remote helper (host: farbox; root: /srv/fm; home: /srv/fm-home; scope: remote work; projects: beta; added 2026-11-01)
EOF
  : > "$home/config/fleet-ledger"
  printf '%s\n' '{"v":1,"ts":1782864100,"event":"task.dispatched","task":"ship-a","kind":"ship"}' \
    '{"v":1,"ts":1782864200,"event":"task.status","task":"ship-a","state":"working","text":"halfway"}' \
    > "$home/state/fleet-ledger.jsonl"
  printf 'sm9\n' > "$home/.fm-secondmate-home"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] vpn-login - Log in to the VPN (repo: sample) (kind: captain) (hold: 動手：登入 VPN) (hold-kind: captain)
  Captain hold set: 2026-07-24T00:00:00Z
- [ ] call-1 - A call (repo: sample) (kind: captain) (hold: 要合併嗎？ 選項：合併 | 先不要) (hold-kind: captain)
  Captain hold set: 2026-07-24T00:00:00Z

## Done
EOF
  mkdir -p "$home/state/inbox"
  # shellcheck disable=SC2086 # the decoy list is a list of words.
  (cd "$home" && sha256sum $SA_DECOYS) > "$home.decoys"
}

# sa_check_decoys <home>: every decoy is byte-identical and state/inbox/ is empty.
sa_check_decoys() {
  (cd "$1" && sha256sum -c --quiet "$1.decoys") >/dev/null 2>&1 ||
    fail "a decoy Firstmate file in $1 changed: $(cd "$1" && sha256sum -c "$1.decoys" 2>&1 | grep -v ': OK$')"
  [ -z "$(ls -A "$1/state/inbox")" ] || fail "the board wrote into $1/state/inbox"
}

# Extra NAME=value words for the clean environment, set by each script.
SA_ENV=()

# sa <home> <fm-topic.sh arguments...>: run the board-only root's command in a
# clean environment. SA_ROOT is the root; SA_CMD_PATH, when set, replaces PATH.
sa() {
  local home=$1
  shift
  sa_assert_scratch "$home"
  env -i HOME="$TMP_ROOT/h" PATH="${SA_CMD_PATH:-$SA_PATH}" LANG=C.UTF-8 TMPDIR="$SA_TMPDIR" FM_HOME="$home" \
    ${SA_ENV[@]+"${SA_ENV[@]}"} "$SA_ROOT/bin/fm-topic.sh" "$@"
}

# sa_code <home> <arguments...>: run like sa, discard output, print the exit code.
sa_code() {
  local rc=0
  sa "$@" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# sa_assert_no_trips: nothing in the board tree ran or sourced a tripwire.
sa_assert_no_trips() {
  [ ! -s "$SA_TRIP_LOG" ] || fail "the board reached Firstmate files: $(cat "$SA_TRIP_LOG")"
}

# sa_assert_no_boards: no board started under the scratch root is left.
sa_assert_no_boards() {
  tb_stop_boards
  ! pgrep -f "board-server.js.*--state $TMP_ROOT/" >/dev/null || fail "a board under $TMP_ROOT is still running"
}
