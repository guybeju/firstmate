#!/usr/bin/env bash
# Firstmate's helpers for reaching a local secondmate home on the topic board's
# behalf, shared by bin/fm-board.sh and bin/fm-topic-board-read.sh. Sourced
# only; defines functions and has no side effects on source.
#
# The caller must already have sourced fm-secondmate-registry-lib.sh and
# fm-topic-lib.sh.

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
