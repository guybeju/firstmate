#!/usr/bin/env bash
# fm-board.sh install-rules and rules: the board's rules go into the captain's
# two preference files as one marked block each, and nothing else in those
# files is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-board-s6)
RULES="$ROOT/fm-board/rules"
BEGIN='<!-- myshape:begin'
END='<!-- myshape:end -->'
OLD_BEGIN='<!-- topic-board:begin'
OLD_END='<!-- topic-board:end -->'

install() {  # <home>
  tb_run "$1" "$BOARD" install-rules
}

# rules_line <home>: the one line fm-board.sh rules prints.
rules_line() {
  tb_run "$1" "$BOARD" rules
}

test_creates_both_files() {
  local home out gap
  home=$(tb_make_home fresh)
  assert_equals "規則：captain.md 未裝；captain-shared.md 未裝" "$(rules_line "$home")" "status must report missing rules"
  out=$(install "$home") || fail "install-rules failed on an empty home: $out"
  assert_contains "$out" "captain.md：新增（v11）" "install-rules must report the new main block"
  assert_contains "$out" "captain-shared.md：新增（v5）" "install-rules must report the new shared block"
  assert_contains "$out" "生效時間" "install-rules must say when the rules take effect"
  assert_contains "$(cat "$home/data/captain.md")" "myshape.sh retract" "the main rules must say how to take back a wrong summary"
  assert_contains "$(cat "$home/data/captain.md")" "myshape.sh find" "the main rules must say how to look up a topic's history"
  assert_contains "$(cat "$home/data/captain.md")" "fm-board.sh split" "the main rules must say how to split a topic"
  assert_contains "$out" "已註冊的 secondmate" "install-rules must list the secondmates"
  assert_equals "$(cat "$RULES/captain.block.md.tmpl")" "$(cat "$home/data/captain.md")" "a new captain.md must be exactly the template"
  assert_equals "$(cat "$RULES/captain-shared.header.md.tmpl" "$RULES/captain-shared.block.md.tmpl")" "$(cat "$home/data/captain-shared.md")" \
    "a new captain-shared.md must be the header followed by the template"
  gap=$(shared_captain_header_valid "$home/data/captain-shared.md") || fail "upstream rejects the new shared file's header (missing: $gap)"
  assert_equals "drwx------" "$(tb_mode "$home/state/fm-board/rules-backup")" "the backup directory must be 0700"
  assert_equals "規則：captain.md 和範本相同（v11）；captain-shared.md 和範本相同（v5）" "$(rules_line "$home")" \
    "status must report installed rules that match the templates"
  pass "install-rules creates both files, and upstream accepts the shared file's header"
}

test_keeps_everything_outside_the_block() {
  local home out before
  home=$(tb_make_home existing)
  printf '# 我的偏好\n- 先問再做\n- 最後一行沒有換行' > "$home/data/captain.md"
  { cat "$RULES/captain-shared.header.md.tmpl"; printf '\n- 共用的偏好\n'; } > "$home/data/captain-shared.md"
  before=$(cat "$home/data/captain.md")
  out=$(install "$home") || fail "install-rules failed on existing files: $out"
  assert_contains "$out" "captain.md：新增（v11），原檔備份在" "appending to an existing file must be reported with its backup"
  assert_equals "$before" "$(head -n 3 "$home/data/captain.md")" "the captain's own lines must be unchanged"
  assert_equals "" "$(sed -n 4p "$home/data/captain.md")" "one blank line must separate the block from what was there"
  assert_equals "$(cat "$RULES/captain.block.md.tmpl")" "$(tail -n +5 "$home/data/captain.md")" "the block must be appended whole"
  assert_equals "$before" "$(cat "$home"/state/fm-board/rules-backup/captain.md.*)" "the backup must be the original file"
  grep -q '^- 共用的偏好$' "$home/data/captain-shared.md" || fail "the shared file's own lines must be kept"
  pass "an existing file keeps its content and gets the block at its end, with a backup"
}

test_replaces_an_old_block_in_place() {
  local home out
  home=$(tb_make_home update)
  {
    printf '# 前面\n\n'
    printf '%s v0（舊版） -->\n舊的規則\n%s\n' "$BEGIN" "$END"
    printf '\n# 後面\n- 不能動\n'
  } > "$home/data/captain.md"
  assert_contains "$(rules_line "$home")" "captain.md 和範本不同（v0）" "status must notice an outdated block"
  out=$(install "$home") || fail "install-rules failed to update: $out"
  assert_contains "$out" "captain.md：已更新（和範本不同（v0） → v11）" "an update must report the old and new versions"
  assert_equals "# 前面" "$(head -n 1 "$home/data/captain.md")" "text before the block must be kept"
  assert_equals "- 不能動" "$(tail -n 1 "$home/data/captain.md")" "text after the block must be kept"
  grep -q '舊的規則' "$home/data/captain.md" && fail "the old block must be gone"
  assert_equals 1 "$(grep -c "^$BEGIN" "$home/data/captain.md")" "there must be exactly one block"
  assert_equals "$(printf '# 前面\n\n'; cat "$RULES/captain.block.md.tmpl"; printf '\n# 後面\n- 不能動\n')" "$(cat "$home/data/captain.md")" \
    "only the block may differ after an update"
  pass "an existing block is replaced whole and in place"
}

# A home holding blocks marked with the previous versions (main v10, shared v4)
# is updated in place to the current ones: the installer finds a block by its
# marker, whatever version the block names.
test_updates_the_previous_version_in_place() {
  local home out main shared
  home=$(tb_make_home previous)
  main=$(head -n 1 "$RULES/captain.block.md.tmpl" | sed 's/.*begin \(v[0-9]*\).*/\1/')
  shared=$(head -n 1 "$RULES/captain-shared.block.md.tmpl" | sed 's/.*begin \(v[0-9]*\).*/\1/')
  { printf '# 前面\n\n'; sed "1s/begin $main/begin v10/" "$RULES/captain.block.md.tmpl"; } > "$home/data/captain.md"
  sed "1s/begin $shared/begin v4/" "$RULES/captain-shared.block.md.tmpl" |
    cat "$RULES/captain-shared.header.md.tmpl" - > "$home/data/captain-shared.md"
  assert_equals "規則：captain.md 和範本不同（v10）；captain-shared.md 和範本不同（v4）" "$(rules_line "$home")" \
    "rules must report the previous versions as differing"
  out=$(install "$home") || fail "install-rules failed on the previous versions: $out"
  assert_contains "$out" "captain.md：已更新（和範本不同（v10） → $main）" "the main block must be updated from v10"
  assert_contains "$out" "captain-shared.md：已更新（和範本不同（v4） → $shared）" "the shared block must be updated from v4"
  assert_equals "規則：captain.md 和範本相同（$main）；captain-shared.md 和範本相同（$shared）" "$(rules_line "$home")" \
    "rules must report the updated blocks as current"
  assert_equals "# 前面" "$(head -n 1 "$home/data/captain.md")" "text before the block must be kept"
  pass "blocks of the previous version (main v10, shared v4) are updated in place"
}

test_second_run_changes_nothing() {
  local home out stamp
  home=$(tb_make_home again)
  install "$home" >/dev/null
  stamp=$(stat -c '%Y %i' "$home/data/captain.md" "$home/data/captain-shared.md" 2>/dev/null ||
    stat -f '%m %i' "$home/data/captain.md" "$home/data/captain-shared.md")
  sleep 1.1
  out=$(install "$home") || fail "a second install-rules failed"
  assert_contains "$out" "captain.md：已是最新（v11）" "an unchanged file must be reported as current"
  assert_contains "$out" "captain-shared.md：已是最新（v5）" "an unchanged shared file must be reported as current"
  assert_equals "$stamp" "$(stat -c '%Y %i' "$home/data/captain.md" "$home/data/captain-shared.md" 2>/dev/null ||
    stat -f '%m %i' "$home/data/captain.md" "$home/data/captain-shared.md")" "an unchanged file must not be rewritten"
  assert_equals 0 "$(find "$home/state/fm-board/rules-backup" -type f | wc -l | tr -d ' ')" "nothing may be backed up when nothing changes"
  printf '多一行\n' >> "$home/data/captain.md"
  assert_contains "$(rules_line "$home")" "captain.md 和範本相同（v11）" "text outside the block does not make the rules differ"
  sed -i.bak 's/停著的項目不派/停著的項目照派/' "$home/data/captain.md"
  assert_contains "$(rules_line "$home")" "captain.md 和範本不同（v11）" "an edit inside the block must show as differing"
  install "$home" >/dev/null
  assert_contains "$(rules_line "$home")" "captain.md 和範本相同（v11）" "install-rules must restore an edited block"
  grep -q '^多一行$' "$home/data/captain.md" || fail "restoring the block must keep the text outside it"
  pass "install-rules is idempotent and status compares the block's content"
}

# A home whose rules were installed under the board's old marker (main v9,
# shared v3, or the older v8 and v2) gets the new blocks in the same place, not
# a second block beside the old one.
# shellcheck disable=SC2016 # the backticks in the planted lines are Markdown code spans.
plant_old_blocks() {  # <home> <main version> <shared version>
  {
    printf '# 前面\n\n'
    printf '%s %s（由 fm-board.sh install-rules 維護，要改請改範本） -->\n' "$OLD_BEGIN" "$2"
    printf -- '- 新工作先用 `fm-topic.sh list` 找它的議題 id\n%s\n' "$OLD_END"
    printf '\n# 後面\n'
  } > "$1/data/captain.md"
  {
    cat "$RULES/captain-shared.header.md.tmpl"
    printf '%s %s（由 fm-board.sh install-rules 維護，要改請改範本） -->\n' "$OLD_BEGIN" "$3"
    printf -- '- 建立 backlog 項目時就跑 `bin/fm-board.sh tag <task-id> <議題 id>`\n%s\n' "$OLD_END"
  } > "$1/data/captain-shared.md"
}

test_replaces_old_marker_blocks_in_place() {
  local home out versions
  for versions in "v9 v3" "v8 v2"; do
    home=$(tb_make_home "old-marker-${versions% *}")
    plant_old_blocks "$home" "${versions% *}" "${versions#* }"
    assert_equals "規則：captain.md 舊標記（${versions% *}）；captain-shared.md 舊標記（${versions#* }）" "$(rules_line "$home")" \
      "rules must report blocks with the old marker as such, never as 未裝"
    out=$(install "$home") || fail "install-rules failed on old-marker blocks: $out"
    assert_contains "$out" "captain.md：已更新（舊標記 ${versions% *} → v11），原檔備份在" "the main block must be updated from the old marker"
    assert_contains "$out" "captain-shared.md：已更新（舊標記 ${versions#* } → v5），原檔備份在" "the shared block must be updated from the old marker"
    assert_equals "$(printf '# 前面\n\n'; cat "$RULES/captain.block.md.tmpl"; printf '\n# 後面\n')" "$(cat "$home/data/captain.md")" \
      "the old main block must be replaced in place"
    assert_equals "$(cat "$RULES/captain-shared.header.md.tmpl" "$RULES/captain-shared.block.md.tmpl")" "$(cat "$home/data/captain-shared.md")" \
      "the old shared block must be replaced in place"
    assert_equals 0 "$(cat "$home/data/captain.md" "$home/data/captain-shared.md" | grep -c '<!-- topic-board:')" \
      "no old marker may be left"
    assert_equals "規則：captain.md 和範本相同（v11）；captain-shared.md 和範本相同（v5）" "$(rules_line "$home")" \
      "rules must report the upgraded blocks as current"
    assert_equals 2 "$(find "$home/state/fm-board/rules-backup" -type f | wc -l | tr -d ' ')" "each file must be backed up once"
  done
  pass "blocks with the board's old marker are replaced in place, from v9 and v3 as from v8 and v2"
}

# A file holding a block under each marker keeps only the new one.
test_drops_an_old_block_beside_a_new_one() {
  local home out where
  for where in old-first new-first; do
    home=$(tb_make_home "both-$where")
    {
      printf '# 前面\n'
      [ "$where" = new-first ] || printf '%s v9 -->\n舊的規則\n%s\n' "$OLD_BEGIN" "$OLD_END"
      printf '# 中間\n'
      printf '%s v11 -->\n新的規則\n%s\n' "$BEGIN" "$END"
      printf '# 再中間\n'
      [ "$where" = old-first ] || printf '%s v9 -->\n舊的規則\n%s\n' "$OLD_BEGIN" "$OLD_END"
      printf '# 後面\n'
    } > "$home/data/captain.md"
    assert_contains "$(rules_line "$home")" "captain.md 和範本不同（v11），另有舊標記（v9）" "status must report both blocks ($where)"
    out=$(install "$home") || fail "install-rules failed with both markers ($where): $out"
    assert_contains "$out" "captain.md：已更新（v11），舊標記的區塊也拿掉了，原檔備份在" "the removal must be reported ($where)"
    assert_equals "$(printf '# 前面\n# 中間\n'; cat "$RULES/captain.block.md.tmpl"; printf '# 再中間\n# 後面\n')" \
      "$(cat "$home/data/captain.md")" "only the new block may remain, in its place ($where)"
    assert_contains "$(rules_line "$home")" "captain.md 和範本相同（v11）" "status must then report one current block ($where)"
  done
  pass "a file with a block under each marker keeps only the new block, in its place"
}

# A broken old marker is refused like a broken new one.
test_refuses_a_broken_old_marker() {
  local home out rc before
  home=$(tb_make_home broken-old)
  printf '%s v9 -->\n規則\n%s v11 -->\n新\n%s\n' "$OLD_BEGIN" "$BEGIN" "$END" > "$home/data/captain.md"
  before=$(cat "$home/data/captain.md")
  rc=0
  out=$(install "$home" 2>&1) || rc=$?
  assert_equals 1 "$rc" "install-rules must fail on an unpaired old marker"
  assert_contains "$out" "captain.md：標記不成對" "install-rules must explain the unpaired old marker"
  assert_equals "$before" "$(cat "$home/data/captain.md")" "the file must be left alone"
  assert_contains "$(rules_line "$home")" "captain.md 標記不完整" "status must report the unpaired old marker"
  pass "an unpaired old marker leaves the file untouched and is reported"
}

# A curation pass or an editor may reshape the marker lines without removing them.
test_finds_reshaped_markers() {
  local home out variant
  for variant in indented trailing-space crlf end-suffix; do
    home=$(tb_make_home "reshaped-$variant")
    {
      printf '# 前面\n\n'
      case "$variant" in
        indented) sed '1s/^/  /; $s/^/  /' "$RULES/captain.block.md.tmpl" ;;
        trailing-space) sed '1s/$/ /; $s/$/  /' "$RULES/captain.block.md.tmpl" ;;
        crlf) sed 's/$/\r/' "$RULES/captain.block.md.tmpl" ;;
        end-suffix) sed '$s/$/ <!--P-->/' "$RULES/captain.block.md.tmpl" ;;
      esac
      printf '\n# 後面\n'
    } > "$home/data/captain.md"
    assert_contains "$(rules_line "$home")" "captain.md 和範本不同（v11）" "status must still find the $variant block"
    out=$(install "$home") || fail "install-rules failed on $variant markers: $out"
    assert_contains "$out" "captain.md：已更新" "the $variant block must be replaced in place"
    assert_equals "$(printf '# 前面\n\n'; cat "$RULES/captain.block.md.tmpl"; printf '\n# 後面\n')" "$(cat "$home/data/captain.md")" \
      "the $variant block must become exactly one clean block"
  done
  pass "a block whose marker lines were indented, padded, or suffixed is still found and replaced"
}

test_refuses_unpaired_markers() {
  local home out rc before variant
  for variant in begin-only end-only two-begins reversed; do
    home=$(tb_make_home "broken-$variant")
    case "$variant" in
      begin-only) printf '%s v1 -->\n規則\n' "$BEGIN" ;;
      end-only) printf '規則\n%s\n' "$END" ;;
      two-begins) printf '%s v1 -->\n%s v1 -->\n%s\n' "$BEGIN" "$BEGIN" "$END" ;;
      reversed) printf '%s\n規則\n%s v1 -->\n' "$END" "$BEGIN" ;;
    esac > "$home/data/captain.md"
    before=$(cat "$home/data/captain.md")
    rc=0
    out=$(install "$home" 2>&1) || rc=$?
    assert_equals 1 "$rc" "install-rules must fail on $variant markers"
    assert_contains "$out" "captain.md：標記不成對" "install-rules must explain the $variant markers"
    assert_equals "$before" "$(cat "$home/data/captain.md")" "a file with $variant markers must be left alone"
    assert_present "$home/data/captain-shared.md" "the other file must still be installed ($variant)"
    assert_contains "$(rules_line "$home")" "captain.md 標記不完整" "status must report the $variant markers"
  done
  pass "a file whose markers do not form one block is left untouched and reported"
}

test_refuses_a_shared_file_with_a_bad_header() {
  local home out rc
  home=$(tb_make_home bad-header)
  printf '# 隨便的檔頭\n- 內容\n' > "$home/data/captain-shared.md"
  rc=0
  out=$(install "$home" 2>&1) || rc=$?
  assert_equals 1 "$rc" "install-rules must fail when the shared header is not upstream's"
  assert_contains "$out" "檔頭不合上游的要求（少了「main-authoritative」）" "the refusal must name the missing phrase"
  assert_equals "$(printf '# 隨便的檔頭\n- 內容\n')" "$(cat "$home/data/captain-shared.md")" "the shared file must be left alone"
  assert_present "$home/data/captain.md" "the main file must still be installed"
  pass "a shared file upstream would reject is not touched"
}

test_main_home_only() {
  local home out rc
  home=$(tb_make_secondmate_home sm sm1)
  rc=0
  out=$(install "$home" 2>&1) || rc=$?
  assert_equals 1 "$rc" "install-rules must fail in a secondmate home"
  assert_contains "$out" "只能在主 home 跑" "the refusal must explain itself"
  assert_absent "$home/data/captain.md" "nothing may be written in a secondmate home"
  assert_absent "$home/data/captain-shared.md" "the read-only shared copy must not be touched"
  assert_absent "$home/state/fm-board" "no directory may be created in a secondmate home"
  expect_code 2 "$(tb_code "$(tb_make_home usage)" "$BOARD" install-rules extra)" "install-rules with an argument"
  pass "install-rules runs only in the main home"
}

test_templates() {
  local name bytes total=0
  for name in captain.block captain-shared.block captain-shared.header; do
    assert_present "$RULES/$name.md.tmpl" "missing template $name"
    bytes=$(wc -c < "$RULES/$name.md.tmpl" | tr -d ' ')
    total=$((total + (bytes + 2) / 3))
  done
  [ "$total" -lt 1600 ] || fail "the three templates cost about $total tokens of startup memory; keep them under 1600"
  for name in captain.block captain-shared.block; do
    assert_equals "$BEGIN" "$(head -n 1 "$RULES/$name.md.tmpl" | cut -c1-${#BEGIN})" "$name must start with the begin marker"
    assert_equals "$END" "$(tail -n 1 "$RULES/$name.md.tmpl")" "$name must end with the end marker"
  done
  pass "the templates are marked blocks and stay small"
}

fm_test_run test_creates_both_files test_keeps_everything_outside_the_block test_replaces_an_old_block_in_place \
  test_updates_the_previous_version_in_place \
  test_second_run_changes_nothing test_finds_reshaped_markers test_refuses_unpaired_markers test_refuses_a_shared_file_with_a_bad_header \
  test_main_home_only test_templates test_replaces_old_marker_blocks_in_place test_drops_an_old_block_beside_a_new_one \
  test_refuses_a_broken_old_marker
