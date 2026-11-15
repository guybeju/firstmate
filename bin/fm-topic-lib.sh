#!/usr/bin/env bash
# Shared helpers for the topic board's two Bash entry points, fm-topic.sh and
# fm-topic-board-read.sh. Sourced only; defines functions and has no side
# effects on source.
#
# The caller must already have sourced fm-secondmate-registry-lib.sh.

# tb_valid_id <value>: 0 when <value> is a usable task id or topic id. The
# grammar is the one topic ids share with task ids: [A-Za-z0-9._-], at most 128
# characters, never starting with '.' or '-' (so it can be neither a hidden
# path component nor mistaken for an option).
tb_valid_id() {
  case "$1" in
    '' | .* | -* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# tb_die <exit-code> <message>: print one line to stderr and exit.
tb_die() {
  local code=$1
  shift
  printf '%s\n' "$*" >&2
  exit "$code"
}

# tb_jq_install_hint: the install line used when jq is missing, worded like
# upstream fm-bootstrap.sh's install_cmd.
tb_jq_install_hint() {
  printf '%s\n' "brew install jq  # or the platform's package manager"
}

# tb_local_secondmate_home <registry-file> <secondmate-id>: print the home of a
# LOCAL registered secondmate. Returns 1 after printing the reason to stderr
# when the id is malformed, unregistered, or remote.
tb_local_secondmate_home() {
  local reg=$1 id=$2 remote home
  tb_valid_id "$id" || {
    printf '%s\n' "--in-home：secondmate id 格式不對：$id" >&2
    return 1
  }
  remote=$(secondmate_registry_field "$reg" "$id" remote) || {
    printf '%s\n' "--in-home：data/secondmates.md 裡沒有 $id" >&2
    return 1
  }
  [ "$remote" = 0 ] || {
    printf '%s\n' "--in-home：$id 是遠端的 secondmate，請改用 bin/fm-on.sh $id" >&2
    return 1
  }
  home=$(secondmate_registry_field "$reg" "$id" home) || return 1
  [ -d "$home" ] || {
    printf '%s\n' "--in-home：$id 的 home 不存在：$home" >&2
    return 1
  }
  printf '%s\n' "$home"
}

# tb_exec_in_home <home> <command...>: replace this process with <command> run
# against <home>. Path overrides that pointed at the calling home are dropped
# so the command resolves state/, data/, and config/ from <home>.
tb_exec_in_home() {
  local home=$1
  shift
  exec env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE FM_HOME="$home" "$@"
}
