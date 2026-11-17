#!/usr/bin/env bash
# shellcheck disable=SC2034 # the marker names and the path list are read by sourcing callers.
# The one definition of what a seeded secondmate home holds beyond its tracked
# checkout: its two identity markers and its captain-private paths.
#
# Secondmate homes and task workers lease copies from the same treehouse pool,
# and a pool slot keeps ignored files across `treehouse return`. Whatever a home
# leaves in its slot is handed to the next holder, so every path that clears a
# home's leftovers reads this list:
#   - bin/fm-teardown.sh stages these paths out of a retired leased home before
#     returning its slot;
#   - bin/fm-home-seed.sh removes the ones a rolled-back seed wrote into a slot
#     it leased before returning it;
#   - bin/fm-spawn.sh clears them from a freshly drawn pooled copy that still
#     carries a secondmate marker before a worker is launched there.
# .claude/settings.local.json is listed because in a persistent home it holds
# the "don't ask again" permission rules granted to that secondmate, and a
# later worker on the slot would inherit them.
#
# A copy counts as a former secondmate home only when it carries one of the two
# markers, because config/, data/, state/ and .env are ordinary names in other
# projects. Removal acts only on the exact listed paths, refuses a listed path
# that holds tracked files or sits under a symlinked directory, and never
# touches commits, branches, tracked files, or uncommitted tracked changes.
#
# Public interface:
#   SUB_HOME_MARKER, SUB_HOME_PARENT_MARKER   - the identity marker names
#   FM_SECONDMATE_HOME_PRIVATE_PATHS          - markers plus private paths
#   fm_secondmate_home_has_marker <copy>      - 0 when either marker is present
#   fm_secondmate_home_present_paths <copy>   - listed paths present, one per line
#   fm_secondmate_home_path_unsafe <copy> <name>
#                                             - prints why a listed path must not
#                                               be moved or removed; 1 when safe
#   fm_secondmate_home_remove_paths <copy> <label> <name>...
#                                             - remove those listed paths; refuses
#                                               before removing any when one is
#                                               unsafe

SUB_HOME_MARKER=".fm-secondmate-home"
SUB_HOME_PARENT_MARKER=".fm-secondmate-parent"
FM_SECONDMATE_HOME_PRIVATE_PATHS=(
  "$SUB_HOME_MARKER" "$SUB_HOME_PARENT_MARKER"
  .env config data state projects .no-mistakes .claude/settings.local.json
)

fm_secondmate_home_has_marker() {  # <copy>
  local copy=$1
  [ -e "$copy/$SUB_HOME_MARKER" ] || [ -L "$copy/$SUB_HOME_MARKER" ] \
    || [ -e "$copy/$SUB_HOME_PARENT_MARKER" ] || [ -L "$copy/$SUB_HOME_PARENT_MARKER" ]
}

fm_secondmate_home_present_paths() {  # <copy>
  local copy=$1 name
  for name in "${FM_SECONDMATE_HOME_PRIVATE_PATHS[@]}"; do
    if [ -e "$copy/$name" ] || [ -L "$copy/$name" ]; then
      printf '%s\n' "$name"
    fi
  done
}

fm_secondmate_home_path_unsafe() {  # <copy> <name>
  local copy=$1 name=$2 parent tracked
  parent=${name%/*}
  while [ "$parent" != "$name" ] && [ -n "$parent" ]; do
    if [ -L "$copy/$parent" ]; then
      printf '%s/%s is a symlink\n' "$copy" "$parent"
      return 0
    fi
    case "$parent" in */*) parent=${parent%/*} ;; *) break ;; esac
  done
  if ! tracked=$(git -C "$copy" ls-files -- "$name" 2>/dev/null); then
    printf 'cannot list tracked files under %s/%s\n' "$copy" "$name"
    return 0
  fi
  if [ -n "$tracked" ]; then
    printf '%s/%s holds tracked files\n' "$copy" "$name"
    return 0
  fi
  return 1
}

fm_secondmate_home_remove_paths() {  # <copy> <label> <name>...
  local copy=$1 label=$2 name why
  shift 2
  for name in "$@"; do
    if why=$(fm_secondmate_home_path_unsafe "$copy" "$name"); then
      echo "REFUSED: will not remove $name from $label $copy: $why" >&2
      return 1
    fi
  done
  for name in "$@"; do
    rm -rf -- "${copy:?}/$name" || {
      echo "error: could not remove $copy/$name from $label" >&2
      return 1
    }
  done
}
