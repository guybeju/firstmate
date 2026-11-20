#!/usr/bin/env bash
# tests/check-signals.sh - static check that no test picks a process to signal
# by its place in the process tree (signal policy P-010, the part that covers
# targets chosen by parentage).
#
# Usage: bash tests/check-signals.sh [file-or-directory...]
#   With no argument it checks every *.sh file under tests/. Prints one
#   "not ok" line per finding and exits 1, or prints "ok" and exits 0.
#
# A finding is any of:
#   - a stand-in, the text of a heredoc a test writes, that reads parentage
#     ($PPID, a ppid field, getppid, /proc/<pid>/stat or status) and also sends
#     a signal to anything other than its own $$;
#   - any line that sends a signal and reads parentage on the same line;
#   - any use of the removed fm-crash-inject shim.
# Reading parentage only to verify or record, and a signal-0 liveness probe,
# are not findings. Comment lines are not checked. There is no exemption list.
#
# Not covered here, and still to be checked under P-010: signals to pids read
# from pid files, to process groups, and by name (pattern-based kill
# commands). This check does not make the test tree compliant with P-010.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -eq 0 ]; then
  set -- "$TEST_DIR"
fi

files=()
for target in "$@"; do
  if [ -d "$target" ]; then
    while IFS= read -r file; do
      files+=("$file")
    done < <(find "$target" -type f -name '*.sh' | LC_ALL=C sort)
  elif [ -f "$target" ]; then
    files+=("$target")
  else
    printf 'not ok - check-signals: no such file or directory: %s\n' "$target" >&2
    exit 2
  fi
done

# The command words are assembled so this file's own text is not a finding.
signal_word='kill'
shim_word='fm-crash-'"inject"

findings=$(awk -v sig="$signal_word" -v shim="$shim_word" '
  function is_comment(line) { return line ~ /^[[:space:]]*#/ }
  function sends_signal(line,    probe, self) {
    if (line ~ ("(^|[^[:alnum:]_-])(p" sig "|" sig "all)([^[:alnum:]_-]|$)")) return 1
    if (line !~ ("(^|[^[:alnum:]_-])" sig "([[:space:]]|$)")) return 0
    probe = "(^|[^[:alnum:]_-])" sig "[[:space:]]+(-0|-s[[:space:]]+0)([^[:alnum:]_]|$)"
    if (line ~ probe) return 0
    return 1
  }
  function signals_only_self(line) {
    return line ~ ("(^|[^[:alnum:]_-])" sig "([[:space:]]+-[[:alnum:]]+)*[[:space:]]+\"?\\\\?\\$\\\\?\\$\"?([^[:alnum:]_]|$)")
  }
  function reads_parentage(line) {
    return line ~ /PPID|ppid|getppid|\/proc\/[^[:space:]]*\/(stat|status)([^[:alnum:]_]|$)/
  }
  function report(what, file, line, text) {
    printf "%s:%d: %s: %s\n", file, line, what, text
  }
  FNR == 1 { in_doc = 0 }
  {
    if (!is_comment($0) && index($0, shim)) report("uses the removed crash-inject shim", FILENAME, FNR, $0)
    if (!is_comment($0) && sends_signal($0) && !signals_only_self($0) && reads_parentage($0))
      report("a signal and a parentage read on one line", FILENAME, FNR, $0)
  }
  in_doc {
    body = $0
    if (strip) sub(/^\t+/, "", body)
    if (body == delim) {
      if (doc_signal && doc_parent)
        report("a stand-in that reads parentage (line " doc_parent ") and signals (line " doc_signal ")", FILENAME, start, doc_text)
      in_doc = 0
      next
    }
    if (!is_comment($0)) {
      if (!doc_signal && sends_signal($0) && !signals_only_self($0)) { doc_signal = FNR; doc_text = $0 }
      if (!doc_parent && reads_parentage($0)) doc_parent = FNR
    }
    next
  }
  !is_comment($0) && match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/) {
    d = substr($0, RSTART, RLENGTH)
    strip = (d ~ /^<<-/)
    sub(/^<<-?[[:space:]]*/, "", d)
    gsub(/["\047]/, "", d)
    delim = d; in_doc = 1; start = FNR; doc_signal = 0; doc_parent = 0; doc_text = ""
  }
' "${files[@]}")

if [ -n "$findings" ]; then
  printf 'not ok - a test picks a process to signal by parentage:\n%s\n' "$findings" >&2
  exit 1
fi
printf 'ok - no test in %s file(s) picks a process to signal by parentage\n' "${#files[@]}"
