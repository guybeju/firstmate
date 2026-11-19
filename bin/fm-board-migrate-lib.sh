#!/usr/bin/env bash
# The one-time move of a home from the board's names before the rename
# (topic-board, fm-topic) to myshape: bin/fm-board.sh migrate-myshape
# [--check | --undo]. Sourced only by bin/fm-board.sh, after its paths, its
# rules functions and the board's library; defines functions and has no side
# effects on source. Kept only until no home has old names left, then removed
# with the other pieces of the move.
#
# Steps, each journaled in state/fm-board/migrate-myshape.journal before it
# acts, under the lock state/fm-board/migrate-myshape.lock/:
#   S1  stop the old service (stop over its socket, else TERM then KILL the
#       pid its pid file names, once that process is proven to be this home's
#       board-server.js)
#   S2  move state/topic-board/rules-backup/* into state/fm-board/rules-backup/
#       (a name already there is left and reported)
#   S0  record the proof baseline: a SHA-256 manifest of every file under
#       state/topic-board and data/topic-board (pid, board.sock, start.lock/
#       and rules-backup/ left out), the topic and archive counts, the events
#       and summaries line counts, the token's hash, and the configured port.
#       It is taken after S1 and S2 so that nothing can still append to the
#       files it covers, and kept as recorded when a run is resumed.
#   S3  mv state/topic-board state/myshape
#   S4  mv data/topic-board data/myshape
#   S5  mv config/topic-board-port config/myshape-port
#   S6  recompute the manifest over the new directories; it must equal S0's
#   S7  re-hold each backlog item whose hold reason starts with the board's
#       old prefix topic-board： with the same reason under the new prefix
#       看板佇列： (bin/fm-tasks-axi.sh hold, which replaces the reason with no
#       gap); the old reason is saved for --undo. A hold that has a kind is
#       left as it is and reported, because re-holding drops the kind.
#   S8  replace each rules block that still has the old marker (install-rules'
#       own replacement); a file without one is left alone
#   S9  move topic-board/{node_modules,coverage,.metrics} of the code root
#       into myshape/ when the target is absent there, then remove the
#       topic-board/ directory if that left it empty
#   S10 start the board with bin/myshape.sh open where one has run, and print
#       its URL
# A secondmate home has no board files: only S9 runs there.
#
# Every step checks the files themselves before it acts, so rerunning after
# an interruption finishes the job and repeats nothing: a move whose source is
# gone and whose target exists is done. --undo reverses what the journal says
# was begun, newest first, again checking the files: a directory is moved back
# only when the new name holds it and the old name is free, a hold only when
# it still has exactly the reason S7 gave it, a rules file whose
# bytes are still what S8 wrote gets its backup back whole, and one changed
# since gets only its old block back in place of the new one. It stops the
# board first and deletes the journal once everything is reversed.
#
# Written for bash 3.2: no mapfile, associative arrays, case-changing
# expansions or /proc.

MIG_DIR=$STATE/fm-board
MIG_JOURNAL=$MIG_DIR/migrate-myshape.journal
MIG_LOCK=$MIG_DIR/migrate-myshape.lock
MIG_SAVE=$MIG_DIR/migrate-myshape.d
MIG_CODE_LEFTOVERS="node_modules coverage .metrics"
MIG_OLD_HOLD='topic-board：'
MIG_NEW_HOLD='看板佇列：'
MIG_FAILED=0
MIG_PARTIAL=0
MIG_CHECKED=0
MIG_NEEDS_TASKS=0

mig_say() {
  printf '%s\n' "$*"
}

mig_fail() {  # <message>: report a step that could not be done; the run ends non-zero.
  printf '%s\n' "$*" >&2
  MIG_FAILED=1
}

mig_journal() {  # <fields...>
  printf '%s\n' "$*" >> "$MIG_JOURNAL"
}

mig_journaled() {  # <exact line>: 0 when the journal holds that line.
  [ -f "$MIG_JOURNAL" ] && grep -qxF "$1" "$MIG_JOURNAL"
}

mig_sha256() {  # <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    shasum -a 256 < "$1" | cut -d' ' -f1
  fi
}

mig_is_secondmate_home() {
  fm_root_is_secondmate_home "$FM_HOME"
}

# mig_unmoved <old> <new>: 0 when the old name is there and the new one is not.
mig_unmoved() {
  [ -e "$1" ] && [ ! -e "$2" ]
}

# --- the old service -------------------------------------------------------

# mig_service_pid <runtime-dir>: the pid in <runtime-dir>/pid when it names a
# live process that is this home's board-server.js; "foreign <pid>" when it
# names any other live process; nothing when there is no live process.
mig_service_pid() {
  local file=$1/pid pid command_line
  [ -f "$file" ] || return 0
  IFS= read -r pid < "$file" || true
  case "$pid" in '' | *[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  command_line=$(ps -o command= -p "$pid" 2>/dev/null || true)
  case "$command_line" in
    *board-server.js*"$STATE"* | *"$STATE"*board-server.js*) printf '%s\n' "$pid" ;;
    *) printf 'foreign %s\n' "$pid" ;;
  esac
}

# mig_socket_answers <socket>: 0 when something accepts a connection on it.
mig_socket_answers() {
  [ -S "$1" ] && command -v node >/dev/null 2>&1 || return 1
  node -e '
    const s = require("node:net").connect(process.argv[1]);
    s.on("connect", () => { s.end(); process.exit(0); });
    s.on("error", () => process.exit(1));
    setTimeout(() => process.exit(1), 3000);
  ' "$1" 2>/dev/null
}

# mig_send_stop <socket>: ask the service on <socket> to stop.
mig_send_stop() {
  node -e '
    const s = require("node:net").connect(process.argv[1]);
    s.on("connect", () => s.write(JSON.stringify({ v: 1, op: "stop", args: {} }) + "\n"));
    s.on("data", () => s.end());
    s.on("close", () => process.exit(0));
    s.on("error", () => process.exit(1));
    setTimeout(() => process.exit(1), 3000);
  ' "$1" >/dev/null 2>&1 || true
}

mig_wait_gone() {  # <pid> <tenths of a second>
  local tries=0
  while kill -0 "$1" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -le "$2" ] || return 1
    sleep 0.1
  done
}

# mig_stop_service <step> <runtime-dir>: stop the service of <runtime-dir>,
# if one runs: stop over its socket, then TERM, then KILL the verified pid.
mig_stop_service() {
  local step=$1 socket=$2/board.sock pid
  pid=$(mig_service_pid "$2")
  case "$pid" in foreign*) mig_fail "${step}：$2/pid 指的是別的程序（${pid#foreign }），沒有停任何東西。"; return 1 ;; esac
  [ -n "$pid" ] || mig_socket_answers "$socket" || return 0
  ! mig_socket_answers "$socket" || mig_send_stop "$socket"
  if [ -n "$pid" ] && ! mig_wait_gone "$pid" 50; then
    kill -TERM "$pid" 2>/dev/null || true
    mig_wait_gone "$pid" 50 || kill -KILL "$pid" 2>/dev/null || true
    mig_wait_gone "$pid" 50 || { mig_fail "${step}：看板服務（pid ${pid}）停不下來。"; return 1; }
  fi
  if mig_socket_answers "$socket"; then
    mig_fail "${step}：$socket 還有服務在回應，但找不到它的程序；沒有搬任何東西。"
    return 1
  fi
  mig_say "${step}：看板服務已停止"
}

# --- moves ------------------------------------------------------------------

# S2: the installer's old backups go where install-rules keeps them now.
mig_move_rules_backups() {
  local from=$STATE/topic-board/rules-backup to=$MIG_DIR/rules-backup file name
  [ -d "$from" ] || return 0
  mkdir -p "$to"
  chmod 700 "$to"
  for file in "$from"/* "$from"/.[!.]*; do
    [ -e "$file" ] || continue
    name=${file##*/}
    if [ -e "$to/$name" ]; then
      mig_say "S2：$to/$name 已經有了，$file 留在原處"
      continue
    fi
    mig_journal "S2 moved $name"
    mv "$file" "$to/$name"
  done
  rmdir "$from" 2>/dev/null && mig_journal "S2 rmdir"
  mig_say "S2：規則備份已移到 $to"
}

# mig_manifest_lines <dir> <label>: "<sha256>  <label>/<path>" for every file
# under <dir> that the move must keep, sorted.
mig_manifest_lines() {
  local dir=$1 label=$2 rel
  [ -d "$dir" ] || return 0
  (cd "$dir" && find . -type f ! -path ./pid ! -path './start.lock/*' ! -path './rules-backup/*' |
    LC_ALL=C sort) | while IFS= read -r rel; do
    rel=${rel#./}
    printf '%s  %s/%s\n' "$(mig_sha256 "$dir/$rel")" "$label" "$rel"
  done
}

mig_line_count() {  # <file>: its line count, or "-" when it does not exist.
  if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else printf -- '-\n'; fi
}

mig_topic_count() {  # <file>
  if [ -f "$1" ]; then jq '.topics | length' "$1" 2>/dev/null || printf '?\n'; else printf -- '-\n'; fi
}

# mig_counts <state-dir> <data-dir> <port-file>: the baseline's key=value lines.
mig_counts() {
  local token=-
  [ ! -f "$1/token" ] || token=$(mig_sha256 "$1/token")
  printf 'topics=%s\n' "$(mig_topic_count "$DATA/topics.json")"
  printf 'archived=%s\n' "$(mig_topic_count "$DATA/topics-archive.json")"
  printf 'events=%s\n' "$(mig_line_count "$2/events.jsonl")"
  printf 'summaries=%s\n' "$(mig_line_count "$2/summaries.jsonl")"
  printf 'token=%s\n' "$token"
  printf 'port=%s\n' "$(cat "$3" 2>/dev/null || printf -- '-')"
}

# S0: record the baseline once, while the old names still hold everything.
mig_record_baseline() {
  [ ! -f "$MIG_SAVE/manifest" ] || return 0
  if [ ! -e "$STATE/topic-board" ] && [ ! -e "$DATA/topic-board" ]; then
    return 0
  fi
  mkdir -p "$MIG_SAVE"
  {
    mig_manifest_lines "$STATE/topic-board" state
    mig_manifest_lines "$DATA/topic-board" data
  } > "$MIG_SAVE/manifest.new"
  mig_counts "$STATE/topic-board" "$DATA/topic-board" "$CONFIG/topic-board-port" > "$MIG_SAVE/baseline"
  mv "$MIG_SAVE/manifest.new" "$MIG_SAVE/manifest"
  mig_say "S0：記下 $(wc -l < "$MIG_SAVE/manifest" | tr -d ' ') 個檔的校驗碼與筆數"
}

# mig_move <step> <old> <new>: one rename(2) from the old name to the new one.
mig_move() {
  local step=$1 old=$2 new=$3
  if mig_unmoved "$old" "$new"; then
    mig_journal "begin $step"
    mv "$old" "$new"
    mig_say "${step}：$old → $new"
  elif [ -e "$old" ]; then
    mig_fail "${step}：$old 和 $new 都在，沒有合併也沒有覆蓋；請手動決定留哪一個。"
    return 1
  fi
}

# S6: the moved files must be the files the baseline recorded. Checked once:
# after it passed, the board may run and append to them.
mig_check_manifest() {
  local differs
  [ -f "$MIG_SAVE/manifest" ] || return 0
  ! mig_journaled "done S6" || return 0
  {
    mig_manifest_lines "$STATE/myshape" state
    mig_manifest_lines "$DATA/myshape" data
  } > "$MIG_SAVE/manifest.after"
  differs=$(diff "$MIG_SAVE/manifest" "$MIG_SAVE/manifest.after" || true)
  if [ -n "$differs" ]; then
    printf '%s\n' "$differs" >&2
    mig_fail "S6：搬過去的檔和搬之前不一樣（上面是差異），停在這裡；跑 bin/fm-board.sh migrate-myshape --undo 搬回去。"
    return 1
  fi
  mig_journal "done S6"
  MIG_CHECKED=1
  mig_say "S6：$(wc -l < "$MIG_SAVE/manifest" | tr -d ' ') 個檔的校驗碼和搬之前相同"
}

# --- holds -------------------------------------------------------------------

# mig_snapshot <file>: this home's fleet snapshot, the backlog with every
# record's hold reason and kind, written to <file>.
mig_snapshot() {
  FM_HOME="$FM_HOME" FM_SNAPSHOT_SECONDMATES=1 FM_SNAPSHOT_BUDGET=1 FM_CREW_STATE_NO_FORGE=1 \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$1" 2>/dev/null && [ -s "$1" ]
}

# mig_old_holds <snapshot>: "<id> <kind or ->" for each record whose hold
# reason still starts with the old prefix.
mig_old_holds() {
  jq -r --arg old "$MIG_OLD_HOLD" '.backlog.records[]
    | select((.hold_reason // "") | startswith($old)) | "\(.id) \(.hold_kind // "-")"' "$1"
}

# mig_hold_reason <snapshot> <id>: that record's hold reason, exactly.
mig_hold_reason() {
  jq -j --arg id "$2" '[.backlog.records[] | select(.id == $id)][0].hold_reason // ""' "$1"
}

mig_read_exact() {  # <file>: its bytes, trailing newlines too.
  local text
  text=$(cat "$1"; printf x)
  printf '%s' "${text%x}"
}

# S7: the board's own holds take the new prefix.
mig_rehold() {
  local snapshot=$MIG_SAVE/snapshot.json id kind old
  mkdir -p "$MIG_SAVE"
  mig_snapshot "$snapshot" || { mig_fail "S7：讀不到 backlog，hold 的開頭沒有換；修好後原樣再跑一次。"; return 0; }
  while read -r id kind; do
    [ -n "$id" ] || continue
    if [ "$kind" != - ]; then
      mig_fail "S7：$id 的 hold 有種類（${kind}），重新 hold 會拿掉種類，沒有換；請手動把開頭改成 ${MIG_NEW_HOLD}"
      continue
    fi
    tb_valid_id "$id" || { mig_fail "S7：看不懂的 id：$id"; continue; }
    mig_hold_reason "$snapshot" "$id" > "$MIG_SAVE/hold.$id.old"
    old=$(mig_read_exact "$MIG_SAVE/hold.$id.old")
    printf '%s' "$MIG_NEW_HOLD${old#"$MIG_OLD_HOLD"}" > "$MIG_SAVE/hold.$id.new"
    mig_journal "begin S7 $id"
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" hold "$id" --reason "$(mig_read_exact "$MIG_SAVE/hold.$id.new")" >/dev/null ||
      { mig_fail "S7：$id 沒有換成功；原樣再跑一次。"; continue; }
    mig_say "S7：$id 的 hold 改成「$(mig_read_exact "$MIG_SAVE/hold.$id.new")」"
  done <<< "$(mig_old_holds "$snapshot")"
}

# mig_unhold_back <snapshot> <id>: S7 undone for one item, when it is still
# held, has no kind, and has exactly the reason S7 gave it.
mig_unhold_back() {
  local snapshot=$1 id=$2 now
  [ -f "$MIG_SAVE/hold.$id.new" ] || return 0
  now=$(jq -r --arg id "$id" '[.backlog.records[] | select(.id == $id)][0] | "\(.hold_kind // "-")"' "$snapshot")
  if [ "$now" != - ] || [ "$(mig_hold_reason "$snapshot" "$id")" != "$(mig_read_exact "$MIG_SAVE/hold.$id.new")" ]; then
    mig_say "還原 S7：$id 現在的 hold 不是搬家時寫的那一個，沒有動"
    return 0
  fi
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" hold "$id" --reason "$(mig_read_exact "$MIG_SAVE/hold.$id.old")" >/dev/null ||
    { mig_fail "還原 S7：$id 沒有換回去。"; return 0; }
  mig_say "還原 S7：$id 的 hold 換回原本的原因"
}

mig_undo_holds() {
  local line snapshot=$MIG_SAVE/snapshot.undo.json
  grep -q '^begin S7 ' "$MIG_JOURNAL" || return 0
  mig_snapshot "$snapshot" || { mig_fail "還原 S7：讀不到 backlog，hold 沒有換回去。"; return 0; }
  while IFS= read -r line; do
    case "$line" in "begin S7 "*) mig_unhold_back "$snapshot" "${line#begin S7 }" ;; esac
  done <<< "$(mig_journal_newest_first)"
}

# --- rules -------------------------------------------------------------------

# mig_rules_kind <file>: none, old, new, both, or broken, by its markers.
mig_rules_kind() {
  local blocks new old
  [ -f "$1" ] || { printf 'none\n'; return 0; }
  blocks=$(rules_blocks "$1")
  new=${blocks%%|*}
  old=${blocks#*|}
  case "$new|$old" in
    broken* | *\|broken*) printf 'broken\n' ;;
    none\|none) printf 'none\n' ;;
    none\|*) printf 'old\n' ;;
    *\|none) printf 'new\n' ;;
    *) printf 'both\n' ;;
  esac
}

# S8 for one file: replace a block that still has the old marker.
mig_install_rules_file() {  # <name> <template> [header-template]
  local name=$1 file=$DATA/$1 kind
  kind=$(mig_rules_kind "$file")
  case "$kind" in
    old | both) ;;
    broken)
      mig_fail "S8：${name} 的標記不成對，沒有動這個檔。請手動整理成一對標記之後再跑一次。"
      return 0
      ;;
    *) return 0 ;;
  esac
  mkdir -p "$MIG_DIR/rules-backup" "$MIG_SAVE"
  chmod 700 "$MIG_DIR/rules-backup"
  RULES_BACKUP=""
  mig_journal "begin S8 $name"
  install_rules_file "$file" "$RULES_DIR/$2" ${3:+"$RULES_DIR/$3"} || {
    mig_fail "S8：${name} 沒有更新。"
    return 0
  }
  cp -p "$file" "$MIG_SAVE/rules.$name.written"
  [ -z "$RULES_BACKUP" ] || mig_journal "S8 backup $name $RULES_BACKUP"
}

mig_install_rules() {
  mig_install_rules_file captain.md captain.block.md.tmpl
  mig_install_rules_file captain-shared.md captain-shared.block.md.tmpl captain-shared.header.md.tmpl
}

# --- the code root -----------------------------------------------------------

# mig_entries <dir>: the names in <dir>, hidden ones too, on one line.
mig_entries() {
  local entry names=""
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$entry" ] || continue
    names="$names ${entry##*/}"
  done
  printf '%s\n' "${names# }"
}

# S9: what a checkout installed under the board's old directory moves along.
mig_tidy_code_root() {
  local old=$FM_ROOT/topic-board new=$FM_ROOT/myshape entry rest
  [ -d "$old" ] || return 0
  mig_journal "begin S9"
  for entry in $MIG_CODE_LEFTOVERS; do
    [ -e "$old/$entry" ] || continue
    if [ -e "$new/$entry" ]; then
      mig_say "S9：$new/$entry 已經有了，$old/$entry 留在原處"
      continue
    fi
    mig_journal "S9 moved $entry"
    mv "$old/$entry" "$new/$entry"
  done
  if rmdir "$old" 2>/dev/null; then
    mig_journal "S9 rmdir"
    mig_say "S9：$old 已清掉"
  else
    rest=$(mig_entries "$old")
    mig_say "S9：$old 還有別的東西，留著沒動：${rest}"
  fi
}

# --- check -------------------------------------------------------------------

# mig_check_pair <old> <new>: one line about a pair; returns 1 on a refusal.
mig_check_pair() {
  if mig_unmoved "$1" "$2"; then
    mig_say "要搬：$1 → $2"
  elif [ -e "$1" ]; then
    mig_say "不能搬：$1 和 $2 都在；請手動決定留哪一個"
    return 1
  fi
}

# mig_check_rules <name>: one line about a rules file. A file whose markers do
# not pair is refused on its own, as install-rules refuses it: the run still
# moves everything else and then ends non-zero.
mig_check_rules() {
  case "$(mig_rules_kind "$DATA/$1")" in
    old | both) mig_say "要換：$1 裡舊標記的規則區塊" ;;
    broken)
      mig_say "不能換：$1 的標記不成對；這個檔不會動，其他照搬，跑完會說沒有全部做完"
      MIG_PARTIAL=1
      ;;
  esac
}

# mig_preflight: what a run would do, one line each; returns 1 when the run
# would be refused before it starts.
mig_preflight() {
  local refused=0 pid leftovers
  if mig_is_secondmate_home; then
    mig_say "secondmate home：沒有看板的檔，不用搬"
  else
    mig_check_pair "$STATE/topic-board" "$STATE/myshape" || refused=1
    mig_check_pair "$DATA/topic-board" "$DATA/myshape" || refused=1
    mig_check_pair "$CONFIG/topic-board-port" "$CONFIG/myshape-port" || refused=1
    pid=$(mig_service_pid "$STATE/topic-board")
    case "$pid" in
      foreign*) mig_say "不能停：state/topic-board/pid 指的是別的程序（${pid#foreign }）"; refused=1 ;;
      ?*) mig_say "要停：舊的看板服務（pid ${pid}）" ;;
    esac
    mig_check_rules captain.md
    mig_check_rules captain-shared.md
    mig_check_holds
    mig_check_tools || refused=1
  fi
  if [ -d "$FM_ROOT/topic-board" ]; then
    leftovers=$(mig_entries "$FM_ROOT/topic-board")
    mig_say "要清：$FM_ROOT/topic-board 裡的 ${leftovers}"
  fi
  return "$refused"
}

# mig_check_holds: the holds S7 would change, and the ones it would leave.
mig_check_holds() {
  local snapshot id kind ids="" kinded=""
  command -v jq >/dev/null 2>&1 || return 0
  snapshot=$(mktemp "${TMPDIR:-/tmp}/fm-board-migrate.XXXXXX")
  if ! mig_snapshot "$snapshot"; then
    rm -f "$snapshot"
    mig_say "讀不到 backlog：看不出有沒有要換開頭的 hold"
    MIG_PARTIAL=1
    return 0
  fi
  while read -r id kind; do
    [ -n "$id" ] || continue
    if [ "$kind" = - ]; then ids="$ids $id"; else kinded="$kinded $id"; fi
  done <<< "$(mig_old_holds "$snapshot")"
  rm -f "$snapshot"
  [ -z "$ids" ] || { mig_say "要換：hold 的開頭 ${MIG_OLD_HOLD} → ${MIG_NEW_HOLD}：${ids# }"; MIG_NEEDS_TASKS=1; }
  [ -z "$kinded" ] || { mig_say "不能換：有種類的 hold 不會換（重新 hold 會拿掉種類）：${kinded# }"; MIG_PARTIAL=1; }
}

mig_check_tools() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  [ "$MIG_NEEDS_TASKS" -eq 0 ] || command -v tasks-axi >/dev/null 2>&1 || missing="$missing tasks-axi"
  if [ -e "$STATE/topic-board/token" ] || [ -e "$STATE/myshape/token" ]; then
    command -v node >/dev/null 2>&1 || missing="$missing node"
  fi
  [ -n "$missing" ] || return 0
  mig_say "缺工具：${missing# }（jq 安裝：$(tb_jq_install_hint)）"
  return 1
}

# mig_done_already: 0 when nothing in this home or its code root still has an old name.
mig_done_already() {
  [ ! -d "$FM_ROOT/topic-board" ] || return 1
  mig_is_secondmate_home && return 0
  [ ! -e "$STATE/topic-board" ] && [ ! -e "$DATA/topic-board" ] && [ ! -e "$CONFIG/topic-board-port" ] || return 1
  case "$(mig_rules_kind "$DATA/captain.md")|$(mig_rules_kind "$DATA/captain-shared.md")" in
    *old* | *both* | *broken*) return 1 ;;
  esac
  mig_no_old_holds
}

# mig_no_old_holds: 0 when no hold in this home's backlog has the old prefix.
mig_no_old_holds() {
  local snapshot rc=0
  snapshot=$(mktemp "${TMPDIR:-/tmp}/fm-board-migrate.XXXXXX")
  if ! mig_snapshot "$snapshot" || [ -n "$(mig_old_holds "$snapshot")" ]; then
    rc=1
  fi
  rm -f "$snapshot"
  return "$rc"
}

# --- the proof ---------------------------------------------------------------

# mig_report_counts: the baseline next to what the moved files hold now.
mig_report_counts() {
  local key before after same=1
  [ -f "$MIG_SAVE/baseline" ] || return 0
  mig_counts "$STATE/myshape" "$DATA/myshape" "$CONFIG/myshape-port" > "$MIG_SAVE/after"
  while IFS='=' read -r key before; do
    after=$(sed -n "s/^$key=//p" "$MIG_SAVE/after")
    [ "$before" = "$after" ] || {
      mig_say "不同：$key 搬之前 ${before}，現在 ${after}"
      same=0
    }
  done < "$MIG_SAVE/baseline"
  [ "$same" -eq 0 ] || mig_say "議題、封存、events、summaries 的筆數，token 與埠號都和搬之前相同"
}

# --- undo --------------------------------------------------------------------

# mig_journal_newest_first: the journal's lines, last one first.
mig_journal_newest_first() {
  awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }' "$MIG_JOURNAL"
}

# mig_move_back <step> <old> <new>: undo one directory or file move.
mig_move_back() {
  mig_journaled "begin $1" || return 0
  if mig_unmoved "$3" "$2"; then
    mv "$3" "$2"
    mig_say "還原 ${1}：$3 → $2"
  elif [ -e "$3" ]; then
    mig_fail "還原 ${1}：$2 和 $3 都在，沒有動；請手動決定留哪一個。"
  fi
}

# mig_restore_rules <name> <backup>: S8 undone for one file. A file still
# holding exactly what S8 wrote gets its backup back whole; one changed since
# gets the backup's old block back in place of its new block, so edits outside
# the block are kept.
mig_restore_rules() {
  local name=$1 backup=$2 file=$DATA/$1 new old fresh
  [ -f "$backup" ] || { mig_fail "還原 S8：${name} 的備份 $backup 不見了，沒有動。"; return 0; }
  if cmp -s "$file" "$MIG_SAVE/rules.$name.written"; then
    cp -p "$backup" "$file"
    mig_say "還原 S8：${name} 換回 $backup"
    return 0
  fi
  new=$(block_at "$file" "$RULES_BEGIN" "$RULES_END")
  old=$(block_at "$backup" "$OLD_RULES_BEGIN" "$OLD_RULES_END")
  case "$new|$old" in
    ok\ *\|ok\ *) ;;
    *)
      mig_fail "還原 S8：${name} 沒有剛好一個新標記的區塊，或備份裡沒有舊區塊，沒有動；舊的檔在 ${backup}。"
      return 0
      ;;
  esac
  fresh="$MIG_DIR/rules.undo.$$"
  block_text "$backup" "$old" > "$fresh.block"
  without_block "$file" "$new" "$fresh.block" > "$fresh"
  rm -f "$fresh.block"
  mv "$fresh" "$file"
  mig_say "還原 S8：${name} 的區塊換回舊標記的那一份（區塊外後來的修改留著）"
}

mig_undo_line() {  # <journal line>
  local from=$STATE/topic-board/rules-backup to=$MIG_DIR/rules-backup rest
  case "$1" in
    "S9 rmdir") [ -e "$FM_ROOT/topic-board" ] || mkdir "$FM_ROOT/topic-board" ;;
    "S9 moved "*)
      if mig_unmoved "$FM_ROOT/myshape/${1#S9 moved }" "$FM_ROOT/topic-board/${1#S9 moved }"; then
        mv "$FM_ROOT/myshape/${1#S9 moved }" "$FM_ROOT/topic-board/${1#S9 moved }"
      fi
      ;;
    "S8 backup "*)
      rest=${1#S8 backup }
      mig_restore_rules "${rest%% *}" "${rest#* }"
      ;;
    "S2 moved "*)
      mkdir -p "$from"
      ! mig_unmoved "$to/${1#S2 moved }" "$from/${1#S2 moved }" || mv "$to/${1#S2 moved }" "$from/${1#S2 moved }"
      ;;
    "S2 rmdir") mkdir -p "$from" ;;
  esac
}

mig_undo() {
  local line
  [ -f "$MIG_JOURNAL" ] || tb_die 1 "沒有搬過的紀錄（${MIG_JOURNAL}），沒有東西可以還原。"
  mig_lock
  mig_stop_service "還原 S10" "$STATE/myshape" || exit 1
  while IFS= read -r line; do
    case "$line" in "S9 "* | "S8 "*) mig_undo_line "$line" ;; esac
  done <<< "$(mig_journal_newest_first)"
  mig_undo_holds
  mig_move_back S5 "$CONFIG/topic-board-port" "$CONFIG/myshape-port"
  mig_move_back S4 "$DATA/topic-board" "$DATA/myshape"
  mig_move_back S3 "$STATE/topic-board" "$STATE/myshape"
  while IFS= read -r line; do
    case "$line" in "S2 "*) mig_undo_line "$line" ;; esac
  done <<< "$(mig_journal_newest_first)"
  [ "$MIG_FAILED" -eq 0 ] || tb_die 1 "沒有全部還原；紀錄留著，照上面的說明處理後原樣再跑一次 --undo。"
  rm -rf "$MIG_SAVE"
  rm -f "$MIG_JOURNAL"
  mig_say "已還原到改名前的名字。要回到改名前的程式，現在可以退回程式再更新。"
}

# --- lock and entry points -------------------------------------------------

mig_lock() {
  local holder
  mkdir -p "$MIG_DIR"
  if ! mkdir "$MIG_LOCK" 2>/dev/null; then
    holder=$(cat "$MIG_LOCK/pid" 2>/dev/null || true)
    case "$holder" in '' | *[!0-9]*) holder="" ;; esac
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      tb_die 1 "另一個 migrate-myshape（pid ${holder}）正在跑；等它結束再試。"
    fi
    rm -rf "$MIG_LOCK"
    mkdir "$MIG_LOCK" || tb_die 1 "拿不到 ${MIG_LOCK}，什麼都沒有做。"
  fi
  printf '%s\n' "$$" > "$MIG_LOCK/pid"
  trap 'rm -rf "$MIG_LOCK"' EXIT
}

mig_run() {
  local url
  mig_preflight || tb_die 1 "有上面列的問題，什麼都沒有搬。"
  mig_lock
  if ! mig_is_secondmate_home; then
    mig_stop_service S1 "$STATE/topic-board" || exit 1
    mig_move_rules_backups
    mig_record_baseline
    mig_move S3 "$STATE/topic-board" "$STATE/myshape" || exit 1
    mig_move S4 "$DATA/topic-board" "$DATA/myshape" || exit 1
    mig_move S5 "$CONFIG/topic-board-port" "$CONFIG/myshape-port" || exit 1
    mig_check_manifest || exit 1
    mig_rehold
    mig_install_rules
  fi
  mig_tidy_code_root
  if ! mig_is_secondmate_home && [ -f "$STATE/myshape/token" ]; then
    mig_journal "begin S10"
    url=$("$SCRIPT_DIR/myshape.sh" open) || mig_fail "S10：看板沒有啟動；修好上面的問題後跑 bin/myshape.sh open。"
    [ -z "$url" ] || mig_say "S10：看板在跑：$url"
    [ "$MIG_CHECKED" -eq 0 ] || mig_report_counts
  fi
  [ "$MIG_FAILED" -eq 0 ] && [ "$MIG_PARTIAL" -eq 0 ] ||
    tb_die 1 "沒有全部做完；照上面的說明處理後原樣再跑一次。"
  mig_done_already || tb_die 1 "還有舊名字留著；跑 bin/fm-board.sh migrate-myshape --check 看是哪些。"
  mig_say "已搬完。要回到改名前的程式，先跑 bin/fm-board.sh migrate-myshape --undo。"
}

mig_check() {
  if mig_done_already; then
    mig_say "已搬完"
    return 0
  fi
  mig_preflight || return 1
  [ "$MIG_PARTIAL" -eq 0 ]
}

cmd_migrate_myshape() {
  case "${1:-}|$#" in
    '|0') mig_run ;;
    --check\|1) mig_check ;;
    --undo\|1) mig_undo ;;
    *) usage_error "migrate-myshape 的用法是 migrate-myshape [--check | --undo]" ;;
  esac
}
