# shellcheck shell=bash
# The finished items tasks-axi's Done retention has moved out of a markdown
# backlog into its archive, so a reader can tell an archived finished id from an
# id nobody knows. Sourced only; it sources bin/fm-tasks-axi-lib.sh and
# bin/fm-backlog-transition-lib.sh for the backlog's own addressing. Written for
# bash 3.2 and BSD tools. bin/fm-fleet-snapshot.sh uses it to resolve blockers.
#
# fm_backlog_archive_path <data-dir>
#   Prints the archive tasks-axi appends to for the backlog <data-dir>/backlog.md,
#   with tasks-axi's own precedence: the [markdown] archive key of the backlog
#   root's .tasks.toml, else of $HOME/.tasks-axi/config.toml (a relative value
#   resolves against the backlog root), else done-archive.md beside the backlog.
#   The backlog root is fm_backlog_root's, the directory tasks-axi runs from.
#   Returns 1, printing nothing, when the data directory cannot be resolved or
#   the configured backend is not markdown and so keeps no archive.
#
# fm_backlog_archived_done_ids <archive>
#   Prints each id with a checked row ("- [x] <id> - ...", the form tasks-axi
#   writes a Done row in) in <archive> once, in first-seen order. A row archived
#   unchecked (`tasks-axi prune --state queued`) is not finished and is skipped.
#   Prints nothing for a missing or unreadable archive; it never fails.

_fm_backlog_archive_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$_fm_backlog_archive_lib_dir/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$_fm_backlog_archive_lib_dir/fm-backlog-transition-lib.sh"

# _fm_backlog_archive_setting <toml-file>: the [markdown] archive value, or nothing.
_fm_backlog_archive_setting() {
  [ -f "$1" ] && [ -r "$1" ] || return 0
  LC_ALL=C awk '
    function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line ~ /^\[[^]]+\]$/) { insection = (line == "[markdown]"); next }
      if (insection && line ~ /^archive[[:space:]]*=/) {
        sub(/^archive[[:space:]]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        print line
        exit
      }
    }
  ' "$1"
}

fm_backlog_archive_path() {  # <data-dir>
  local data root backend archive
  data=$(fm_backlog_data_absolute "$1" 2>/dev/null) || return 1
  root=$(fm_backlog_root "$data") || return 1
  backend=$(fm_tasks_axi_backend "$root" 2>/dev/null) || return 1
  [ "$backend" = markdown ] || return 1
  archive=$(_fm_backlog_archive_setting "$root/.tasks.toml")
  if [ -z "$archive" ] && [ -n "${HOME:-}" ]; then
    archive=$(_fm_backlog_archive_setting "$HOME/.tasks-axi/config.toml")
  fi
  case "$archive" in
    '') printf '%s/done-archive.md\n' "${data%/}" ;;
    /*) printf '%s\n' "$archive" ;;
    *) printf '%s/%s\n' "${root%/}" "$archive" ;;
  esac
}

fm_backlog_archived_done_ids() {  # <archive>
  [ -f "$1" ] && [ -r "$1" ] || return 0
  LC_ALL=C awk '
    /^[-*] \[[xX]\] [^[:space:]]+[[:space:]]+-[[:space:]]/ {
      id = substr($0, 7)
      sub(/[[:space:]].*$/, "", id)
      if (!(id in seen)) { seen[id] = 1; print id }
    }
  ' "$1" 2>/dev/null || true
}
