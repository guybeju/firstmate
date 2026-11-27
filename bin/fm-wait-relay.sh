#!/usr/bin/env bash
# fm-wait-relay.sh - tell a home's supervising firstmate about every backlog wait nothing else owns.
#
# Usage:
#   fm-wait-relay.sh list
#   fm-wait-relay.sh relay
#   fm-wait-relay.sh --help
#
# Fork-only (guybeju/firstmate carry). A backlog row held with a kind other
# than `captain` (tasks-axi's parked, external, load, future) waits on someone,
# yet no other script publishes it, no read surface treats it as a decision,
# and an answer given in another home never closes it. This script owns that
# class: it raises each such row to the firstmate that must dispose of it, and
# keeps raising it until the row leaves the class.
#
# THE CLASS (this script is the single owner of the predicate). An unowned wait
# is a row of this home's backlog that:
#   - is Queued or In flight;
#   - carries a hold record whose hold kind is set and is not `captain`;
#   - has no hold-until date after today (UTC); tasks-axi stops counting a
#     dated hold as active on that date, so the row is due again from then;
#   - has no unresolved blocker known to this home. A blocker counts only while
#     it is a Queued or In-flight row of this same backlog. A done or archived
#     blocker, and an id this home does not carry at all (another home's task),
#     count as no blocker, so a dependency on another home never hides a row.
# Kindless holds stay out: in this fork their one writer is
# bin/fm-dispatch-plan.sh's board-queue hold, which the captain releases by
# moving the topic. A hold that waits on a person names its kind.
# The owner of an unowned wait is the home's supervising firstmate: the parent
# firstmate for a secondmate home, the main firstmate itself in a main home.
# .agents/skills/captain-hold-lifecycle/SKILL.md "Waits on firstmate" owns how
# the owner disposes of one.
#
# The backlog is read once per run through tasks-axi's own listing (any
# configured backend). A listing that cannot be read, is truncated, or does not
# have the expected shape is a failed read, never an empty class: both commands
# then exit 1 and change nothing.
#
# `list` (read-only, any home) prints one line per unowned wait, in backlog
# order, with tabs and line breaks in the free text folded to spaces:
#   <id> TAB <state> TAB <kind> TAB <title> TAB <reason>
# and nothing when there is none. In a main home bin/fm-wake-drain.sh prints it
# as the WAITS ON FIRSTMATE section.
#
# `relay` runs only in a secondmate home; in a main home it is a silent no-op
# (exit 0), because the main home has no parent and its drain shows the list.
# It compares the class with its receipts and publishes on the parent channel
# through bin/fm-parent-channel-lib.sh (local and remote routes alike):
#   - a row in the class with no receipt:
#       needs-decision [key=wait-<id>-<n>]: <kind> wait <id>: <title>: <reason>
#   - a receipt whose row left the class:
#       resolved [key=wait-<id>-<n>]: released | closed | now a captain call
#                                     | dated <YYYY-MM-DD> | waits on <blocker>
#   - a receipt older than FM_WAIT_RELAY_REPEAT_SECS (default 86400, a positive
#     whole number) whose row is still in the class: it resolves <n> as
#     `still waiting, raised again as wait-<id>-<n+1>` and then publishes <n+1>,
#     so an answer that was lost or never applied cannot go silent.
# <n> for a row with no receipt is one more than the highest wait-<id>-<n> the
# channel already carries, so a row that left the class and came back opens a
# new decision; when that highest key's newest line is still an open
# needs-decision (a run that published but died before its receipt), the run
# adopts it and republishes the same line, which the channel deduplicates.
# The receipts file state/.wait-relay holds one line per OPEN wait:
#   <task> <key> <published-epoch>
# Only this command writes it, under state/.wait-relay.lock, replacing it
# atomically after the channel appends, so a crash at any point converges on
# the next run. A receipt is written only after its line reached the channel
# and removed only after its resolution did. The receipts, not the channel, say
# what is open, so the parent's own `fm-send.sh --resolve-key wait-<id>-<n>`
# line (written in the parent's state for local and remote mates alike) never
# makes the relay reopen that key: the row stays raised until its own state
# changes, and only the daily repeat raises it again.
# bin/fm-supervision-lib.sh counts the lines here as open waits, so a mate with
# open waits keeps its watcher.
#
# Triggers (each independent of the others):
#   - record time: bin/fm-tasks-axi.sh after a successful mutating command in a
#     secondmate home, bounded and best-effort;
#   - session start: bin/fm-inactive-reconcile.sh scan --startup;
#   - every watcher poll: bin/fm-inactive-reconcile.sh scan, right after its
#     ledger-first parent delivery and inside its budget.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE select the home as
# in every Firstmate script; FM_WAIT_RELAY_REPEAT_SECS as above;
# FM_WAIT_RELAY_NOW (epoch seconds) replaces the clock, for deterministic tests.
#
# Exit status: 0 done (nothing to do included); 1 the backlog could not be
# read, or a parent-channel append or the receipts write failed (an
# `actionable:` line on stderr names it, and the next run retries); 2 usage, an
# invalid setting, or an unusable .fm-secondmate-home marker.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECEIPTS="$STATE/.wait-relay"
RELAY_LOCK="$STATE/.wait-relay.lock"
LIST_FIELDS=held,hold_kind,hold_until,blocked_by,hold_reason
LIST_HEADER_FIELDS="id,state,kind,repo,title,$LIST_FIELDS"
LIST_LIMIT=100000

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  list|relay) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

now_epoch() {
  case "${FM_WAIT_RELAY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_WAIT_RELAY_NOW" ;;
  esac
}

utc_date_of() {  # <epoch>
  date -u -r "$1" +%Y-%m-%d 2>/dev/null || date -u -d "@$1" +%Y-%m-%d 2>/dev/null
}

# The whole backlog as normalized rows, one per line:
#   <id> TAB <state> TAB <held-record 0|1> TAB <kind> TAB <until> TAB <blockers> TAB <title> TAB <reason>
# where an absent value is empty and <blockers> is comma-separated. Non-zero,
# printing nothing, on any read that is not a complete listing of the expected
# shape (see the header).
backlog_rows() {
  local data listing
  data=$(fm_backlog_data_absolute "$DATA" 2>/dev/null) || return 1
  command -v tasks-axi >/dev/null 2>&1 || return 1
  listing=$(fm_backlog_row_list "$data" --fields "$LIST_FIELDS" --limit "$LIST_LIMIT") || return 1
  printf '%s\n' "$listing" | awk -v header="$LIST_HEADER_FIELDS" '
    function fold(s) { gsub(/[\t\r\n]/, " ", s); return s }
    # One TOON value: a bare run up to the next comma, or a double-quoted
    # string with backslash escapes. Sets VALUE and returns the position after
    # the value (at a comma or past the end), or 0 when the quoting is broken.
    function take(s, pos,    c, out, n) {
      n = length(s)
      if (substr(s, pos, 1) != "\"") {
        out = ""
        while (pos <= n && substr(s, pos, 1) != ",") { out = out substr(s, pos, 1); pos++ }
        VALUE = out
        return pos
      }
      pos++
      out = ""
      while (pos <= n) {
        c = substr(s, pos, 1)
        if (c == "\\") {
          pos++
          c = substr(s, pos, 1)
          if (c == "n" || c == "r" || c == "t") c = " "
          out = out c
        } else if (c == "\"") {
          VALUE = out
          return pos + 1
        } else {
          out = out c
        }
        pos++
      }
      return 0
    }
    function dash(v) { return v == "-" ? "" : v }
    BEGIN { want = -1; seen = 0; bad = 0; nfields = split(header, names, ",") }
    want < 0 && /^count: [0-9]+$/ { total = substr($0, 8) + 0; counted = 1; next }
    want < 0 && /^count: / { bad = 1; next }
    want < 0 && /^tasks: 0 tasks/ { want = 0; next }
    want < 0 && /^tasks\[[0-9]+\]\{/ {
      if ($0 != "tasks[" substr($0, 7, index($0, "]") - 7) "]{" header "}:") { bad = 1; next }
      want = substr($0, 7, index($0, "]") - 7) + 0
      next
    }
    want > 0 && seen < want && /^  / {
      line = substr($0, 3); pos = 1
      for (i = 1; i <= nfields; i++) {
        pos = take(line, pos)
        if (pos == 0) { bad = 1; next }
        f[i] = VALUE
        if (i < nfields) {
          if (substr(line, pos, 1) != ",") { bad = 1; next }
          pos++
        }
      }
      if (pos <= length(line)) { bad = 1; next }
      seen++
      held = (dash(f[10]) != "") ? 1 : 0
      printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", fold(f[1]), fold(f[2]), held, fold(dash(f[7])), \
        fold(dash(f[8])), fold(f[9] == "none" ? "" : f[9]), fold(f[5]), fold(dash(f[10]))
      next
    }
    END {
      if (bad || !counted || want < 0 || seen != want || total != want) exit 1
    }
  ' || return 1
}

# The pure class predicate over backlog_rows output on stdin. Prints every
# normalized row annotated with its class verdict:
#   <in-class 1|0> TAB <why-not> TAB <normalized row...>
# <why-not> is the resolution reason when the row is outside the class.
classify_rows() {  # <today>
  awk -F '\t' -v today="$1" '
    { n++; id[n] = $1; st[n] = $2; held[n] = $3; kind[n] = $4; until_[n] = $5; blk[n] = $6; row[n] = $0
      if ($2 == "queued" || $2 == "in_flight") open[$1] = 1 }
    END {
      for (i = 1; i <= n; i++) {
        why = ""
        if (st[i] != "queued" && st[i] != "in_flight") why = "closed"
        else if (held[i] != 1 || kind[i] == "") why = "released"
        else if (kind[i] == "captain") why = "now a captain call"
        else if (until_[i] != "" && until_[i] > today) why = "dated " until_[i]
        else {
          waits = ""
          k = split(blk[i], b, ",")
          for (j = 1; j <= k; j++) if (b[j] != "" && (b[j] in open)) waits = waits (waits == "" ? "" : ",") b[j]
          if (waits != "") why = "waits on " waits
        }
        printf "%d\t%s\t%s\n", (why == "" ? 1 : 0), why, row[i]
      }
    }'
}

classified_backlog() {
  local rows today
  rows=$(backlog_rows) || return 1
  today=$(utc_date_of "$(now_epoch)") || return 1
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | classify_rows "$today"
}

command_list() {
  local classified
  classified=$(classified_backlog) || {
    printf 'fm-wait-relay: the backlog of %s could not be read as a complete listing\n' "$FM_HOME" >&2
    exit 1
  }
  [ -n "$classified" ] || return 0
  printf '%s\n' "$classified" | awk -F '\t' -v OFS='\t' '$1 == 1 { print $3, $4, $6, $9, $10 }'
}

# The relay's whole decision as a pure function of the classified backlog
# (first file) and the receipts (second file), one action per line, its fields
# separated by the unit separator (octal 037) so an empty field keeps its place:
#   open    <task> <kind> <title> <reason>
#   keep    <task> <key> <epoch>
#   reraise <task> <key> <epoch> <next-key> <kind> <title> <reason>
#   resolve <task> <key> <epoch> <why>
# A receipt line that is not `<task> wait-<task>-<n> <epoch>`, or repeats a
# task already receipted, is dropped.
plan_actions() {  # <classified-file> <receipts-file> <now> <repeat-secs>
  awk -F '\t' -v OFS='\037' -v now="$3" -v repeat="$4" '
    FNR == NR { if ($1 == 1) { inclass[$3] = 1; kind[$3] = $6; title[$3] = $9; reason[$3] = $10 }
                else why[$3] = $2
                order[++n] = $3; next }
    {
      if (split($0, r, " ") != 3) next
      task = r[1]; key = r[2]; at = r[3]
      if (task !~ /^[A-Za-z0-9._-]+$/ || at !~ /^[0-9]+$/) next
      prefix = "wait-" task "-"
      if (substr(key, 1, length(prefix)) != prefix) next
      occ = substr(key, length(prefix) + 1)
      if (occ !~ /^[0-9]+$/ || (task in receipted)) next
      receipted[task] = 1
      if (task in inclass) {
        if (now - at >= repeat) print "reraise", task, key, at, prefix (occ + 1), kind[task], title[task], reason[task]
        else print "keep", task, key, at
      } else {
        print "resolve", task, key, at, (task in why) ? why[task] : "closed"
      }
    }
    END {
      for (i = 1; i <= n; i++) if ((order[i] in inclass) && !(order[i] in receipted)) {
        t = order[i]; print "open", t, kind[t], title[t], reason[t]
      }
    }' "$1" "$2"
}

# The occurrence a row with no receipt opens: see the header.
fresh_occurrence() {  # <task-id> <channel-path>
  local task=$1 channel=$2
  if [ ! -f "$channel" ]; then
    printf '1\n'
    return 0
  fi
  grep -F "[key=wait-$task-" "$channel" 2>/dev/null | awk -v prefix="[key=wait-$task-" '
    {
      p = index($0, prefix)
      if (p == 0) next
      rest = substr($0, p + length(prefix))
      e = index(rest, "]")
      if (e < 2) next
      occ = substr(rest, 1, e - 1)
      if (occ !~ /^[0-9]+$/) next
      occ += 0
      last[occ] = $1
      if (occ > max) max = occ
    }
    END {
      if (max > 0 && last[max] == "needs-decision") print max
      else print max + 1
    }'
}

RELAY_FAILED=0
publish() {  # <key> <line>
  local rc=0
  fm_parent_channel_report "$FM_HOME" "$STATE" "$2" "$1" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  printf 'actionable: %s did not reach the parent channel of %s (rc=%s)\n' "$1" "$FM_HOME" "$rc" >&2
  RELAY_FAILED=1
  return 1
}

open_line() {  # <key> <task> <kind> <title> <reason>
  fm_parent_channel_clean_note "needs-decision [key=$1]: $3 wait $2: $4: $5"
}

# Each action publishes first and records its receipt after; a publish that
# fails keeps the receipt as it was, so the next run retries the same step.
apply_actions() {  # <actions-file> <new-receipts-file> <now> <channel-path>
  local actions=$1 out=$2 now=$3 channel=$4 verb task a b c d e f key
  while IFS=$'\037' read -r verb task a b c d e f; do
    case "$verb" in
      keep)
        printf '%s %s %s\n' "$task" "$a" "$b" >> "$out" ;;
      resolve)
        publish "$a" "resolved [key=$a]: $(fm_parent_channel_clean_note "$c")" \
          || printf '%s %s %s\n' "$task" "$a" "$b" >> "$out" ;;
      reraise)
        if publish "$a" "resolved [key=$a]: still waiting, raised again as $c" \
          && publish "$c" "$(open_line "$c" "$task" "$d" "$e" "$f")"; then
          printf '%s %s %s\n' "$task" "$c" "$now" >> "$out"
        else
          printf '%s %s %s\n' "$task" "$a" "$b" >> "$out"
        fi ;;
      open)
        key="wait-$task-$(fresh_occurrence "$task" "$channel")"
        if publish "$key" "$(open_line "$key" "$task" "$a" "$b" "$c")"; then
          printf '%s %s %s\n' "$task" "$key" "$now" >> "$out"
        fi ;;
    esac
  done < "$actions"
}

RELAY_WORK=
relay_cleanup() {
  fm_lock_release "$RELAY_LOCK"
  [ -n "$RELAY_WORK" ] || return 0
  rm -f -- "$RELAY_WORK/classified" "$RELAY_WORK/receipts" "$RELAY_WORK/actions" "$RELAY_WORK/next"
  rmdir -- "$RELAY_WORK" 2>/dev/null || true
}

command_relay() {
  local rc=0 repeat=${FM_WAIT_RELAY_REPEAT_SECS:-86400} classified now channel work
  case "$repeat" in ''|*[!0-9]*|0) printf 'fm-wait-relay: FM_WAIT_RELAY_REPEAT_SECS must be a positive whole number\n' >&2; exit 2 ;; esac
  # shellcheck source=bin/fm-parent-channel-lib.sh
  . "$SCRIPT_DIR/fm-parent-channel-lib.sh"
  fm_parent_channel_home_id "$FM_HOME" >/dev/null || rc=$?
  case "$rc" in
    0) ;;
    1) exit 0 ;;
    *) printf 'fm-wait-relay: the .fm-secondmate-home marker of %s is unusable\n' "$FM_HOME" >&2; exit 2 ;;
  esac
  channel=$(fm_parent_channel_destination "$FM_HOME" "$STATE") || {
    printf 'actionable: the parent binding .fm-secondmate-parent of %s is missing or unreadable; waits stay unrelayed\n' "$FM_HOME" >&2
    exit 1
  }
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$RELAY_LOCK" || exit 1
  trap relay_cleanup EXIT
  classified=$(classified_backlog) || {
    printf 'fm-wait-relay: the backlog of %s could not be read as a complete listing; nothing relayed\n' "$FM_HOME" >&2
    exit 1
  }
  now=$(now_epoch)
  work=$(mktemp -d "$STATE/.wait-relay.work.XXXXXX") || exit 1
  RELAY_WORK=$work
  printf '%s' "$classified" > "$work/classified"
  [ -n "$classified" ] && printf '\n' >> "$work/classified"
  if [ -f "$RECEIPTS" ] && [ ! -L "$RECEIPTS" ]; then
    cat "$RECEIPTS" > "$work/receipts" || exit 1
  else
    : > "$work/receipts"
  fi
  plan_actions "$work/classified" "$work/receipts" "$now" "$repeat" > "$work/actions" || exit 1
  : > "$work/next"
  apply_actions "$work/actions" "$work/next" "$now" "$channel"
  if ! cmp -s "$work/next" "$work/receipts"; then
    mv -f "$work/next" "$RECEIPTS" || {
      printf 'actionable: the wait receipts %s could not be written\n' "$RECEIPTS" >&2
      exit 1
    }
  fi
  [ "$RELAY_FAILED" -eq 0 ] || exit 1
}

case "$1" in
  list) command_list ;;
  relay) command_relay ;;
esac
