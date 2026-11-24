#!/usr/bin/env bash
# tests/check-signals.sh - static check that no test signals a computed target
# outside the guarded helper (signal policy P-010 and its first supplement).
#
# Usage: bash tests/check-signals.sh [file-or-directory...]
#   With no argument it checks every text file under the test directories:
#   tests/, myshape/test/, fm-board/test/ and dispatch-plan/test/. Prints one
#   "not ok" block listing every finding and exits 1, or prints "ok" and exits 0.
#   bin/fm-lint.sh runs it with no argument in every mode.
#
# A finding is any of:
#   - a signal sent to a target that is computed rather than the sending
#     shell's own freshly recorded $!: a pid read from a file (a command
#     substitution of cat, sed, head, tail, awk, cut, jq, grep, tr or a
#     redirection, or a variable filled by read), a process group (a
#     negative pid, `-- -$x`, Perl `kill SIG, -$x`, Python killpg, Node
#     process.kill(-x)), a process found by name or pattern (the p- and -all
#     signal commands, xargs, pgrep, pidof), by command line (ps, lsof,
#     fuser), by walking the process tree ($PPID, a ppid field, getppid), or
#     a pid that came out of another command's output (`pid=$(start_x)`, which
#     is usually a grandchild, not a child of the sending shell);
#   - a stand-in, the text of a heredoc a test writes, that reads parentage
#     and also signals anything other than its own $$;
#   - any line that sends a signal and reads parentage on the same line;
#   - any use of the removed fm-crash-inject shim.
# A target's form comes from where its variable is assigned in the same
# function or heredoc (falling back to the file's top level), so a variable
# assigned only from $! is an own child and a pid the guarded helper printed
# ("$SIGNAL_CHECK" or signal-guard.sh in the substitution) is guarded. Signal
# 0 probes, `kill -l`, comment lines, and signal words inside a quoted string
# that is data (not after -c, -e, eval, trap, printf or echo) are not
# findings. There is no exemption list; the helper passes its verified target
# to its own send through a plain variable.
#
# Not covered here: a pid passed as a positional parameter ($1) or assigned in
# another file or function is not followed, and a Python or Node pid read from
# a file is not recognised; the inventory and review cover those.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
if [ "$#" -eq 0 ]; then
  set -- "$TEST_DIR"
  for dir in myshape/test fm-board/test dispatch-plan/test; do
    [ ! -d "$ROOT_DIR/$dir" ] || set -- "$@" "$ROOT_DIR/$dir"
  done
fi

files=()
for target in "$@"; do
  if [ -d "$target" ]; then
    while IFS= read -r file; do
      files+=("$file" "$file")
    done < <(find "$target" -type f -exec grep -Il . {} + | LC_ALL=C sort)
  elif [ -f "$target" ]; then
    files+=("$target" "$target")
  else
    printf 'not ok - check-signals: no such file or directory: %s\n' "$target" >&2
    exit 2
  fi
done
checked=$((${#files[@]} / 2))
[ "$checked" -gt 0 ] || { printf 'not ok - check-signals: no files to check\n' >&2; exit 2; }

# The command words are assembled so this file's own text is not a finding.
# Each file is read twice: the first pass collects assignments, the second
# reports.
findings=$(awk -v sig='kill' -v shim='fm-crash-'"inject" '
  function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
  function is_comment(l) { return l ~ /^[[:space:]]*#/ }
  function note(name, kind) {
    if (kind != "") kinds[scope SUBSEP name] = kinds[scope SUBSEP name] " " kind
  }
  function subst_kind(body,   cmd) {
    if (body ~ /PPID|ppid|getppid/) return "ancestry"
    if (body ~ /SIGNAL_CHECK|signal-guard\.sh/) return "guarded"
    body = trim(body)
    sub(/^(command|env)[[:space:]]+/, "", body)
    cmd = body; sub(/[[:space:]].*/, "", cmd)
    if (cmd ~ /^(cat|head|tail|sed|awk|cut|jq|grep|tr)$/ || cmd ~ /^</) return "pidfile"
    if (cmd ~ /^(pgrep|pidof)$/) return "name"
    if (cmd ~ /^(ps|lsof|fuser)$/) return "cmdline"
    return "subst"
  }
  function rhs_kind(r,   b) {
    sub(/^["\047]/, "", r)
    if (r ~ /^\$\$/) return "self"
    if (r ~ /^\$!/) return "own"
    if (r ~ /^\$\(/) return subst_kind(substr(r, 3))
    if (r ~ /^`/) return subst_kind(substr(r, 2))
    if (r ~ /^\$\{?[A-Za-z_]/) { b = r; sub(/^\$\{?/, "", b); sub(/[^A-Za-z0-9_].*/, "", b); return "alias:" b }
    return ""
  }
  function collect(line,   s, tok, name, rest, w, n, i, list) {
    s = line
    while (match(s, /(^|[^A-Za-z0-9_$])[A-Za-z_][A-Za-z0-9_]*=/)) {
      tok = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH)
      sub(/^[^A-Za-z_]/, "", tok); name = substr(tok, 1, length(tok) - 1)
      note(name, rhs_kind(rest))
      s = rest
    }
    if (match(line, /(^|[^A-Za-z0-9_-])read[[:space:]]/)) {
      rest = substr(line, RSTART + RLENGTH)
      sub(/[<;|&].*/, "", rest)
      n = split(rest, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) note(w[i], "read")
    }
    if (match(line, /(^|[^A-Za-z0-9_-])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]/)) {
      tok = substr(line, RSTART, RLENGTH); rest = substr(line, RSTART + RLENGTH)
      sub(/^[^f]*for[[:space:]]+/, "", tok); sub(/[[:space:]].*/, "", tok)
      list = trim(rest)
      if (list ~ /^["]?\$\(/ || list ~ /^`/ || list ~ /^["]?\$\{?[A-Za-z_]/) note(tok, rhs_kind(list))
    }
  }
  function rank(t) {
    if (t == "ancestry") return 9
    if (t == "group") return 8
    if (t == "name") return 7
    if (t == "cmdline") return 6
    if (t == "pidfile") return 5
    if (t == "read") return 4
    if (t == "subst") return 3
    if (t == "param") return 2
    if (t == "own" || t == "self" || t == "guarded") return 1
    return 0
  }
  function pick(a, b) { return rank(b) > rank(a) ? b : a }
  function lookup(name, depth,   k, a, n, i, best, t) {
    if (depth > 4) return "plain"
    k = kinds[scope SUBSEP name]
    if (k == "" && scope != "global" && scope !~ /^doc/) k = kinds["global" SUBSEP name]
    best = ""
    n = split(k, a, " ")
    for (i = 1; i <= n; i++) {
      t = a[i]
      if (t ~ /^alias:/) t = lookup(substr(t, 7), depth + 1)
      best = pick(best, t)
    }
    return best == "" ? "plain" : best
  }
  function quote_open(line, pos,   i, c, st, op) {  # the quote enclosing column pos, or 0
    st = ""; op = 0
    for (i = 1; i < pos; i++) {
      c = substr(line, i, 1)
      if (st == "\047") { if (c == "\047") { st = ""; op = 0 } continue }
      if (c == "\\") { i++; continue }
      if (st == "\"") { if (c == "\"") { st = ""; op = 0 } continue }
      if (c == "\047" || c == "\"") { st = c; op = i }
    }
    return op
  }
  function command_position(line, pos,   op, before, prefix) {
    op = quote_open(line, pos)
    if (op > 0) {
      before = substr(line, 1, op - 1)
      if (before !~ /(^|[[:space:]])(-[a-z]*[ce]|eval|trap|printf|echo)[[:space:]]*$/) return 0
      prefix = substr(line, op + 1, pos - op - 1)
    } else {
      prefix = substr(line, 1, pos - 1)
    }
    prefix = trim(prefix)
    if (prefix == "") return 1
    return prefix ~ /([;&|(){!`]|\$\(|(^|[^A-Za-z0-9_-])(then|do|else|elif|if|while|until|command|exec|xargs|sudo|nohup|builtin|time|env))$/
  }
  function cut_args(rest,   i, c, st, depth, out) {  # the arguments, up to the command end
    st = ""; depth = 0; out = ""
    for (i = 1; i <= length(rest); i++) {
      c = substr(rest, i, 1)
      if (st == "\047") { if (c == "\047") st = ""; out = out c; continue }
      if (c == "\\") { out = out c substr(rest, i + 1, 1); i++; continue }
      if (st == "\"") {
        if (c == "\"" && depth == 0) st = ""
        else if (c == "$" && substr(rest, i + 1, 1) == "(") { depth++; out = out "$("; i++; continue }
        else if (c == ")" && depth > 0) depth--
        out = out c; continue
      }
      if (c == "$" && substr(rest, i + 1, 1) == "(") { depth++; out = out "$("; i++; continue }
      if (depth > 0) { if (c == ")") depth--; else if (c == "(") depth++; out = out c; continue }
      if (c == "\047" || c == "\"") { st = c; out = out c; continue }
      if (c ~ /[;|&)<>`#]/) break
      out = out c
    }
    return out
  }
  function words(args,   i, c, st, depth, cur, n) {  # splits into W at depth 0 outside quotes
    n = 0; cur = ""; st = ""; depth = 0
    for (i = 1; i <= length(args); i++) {
      c = substr(args, i, 1)
      if (st == "\047") { if (c == "\047") st = ""; cur = cur c; continue }
      if (c == "\\") { cur = cur c substr(args, i + 1, 1); i++; continue }
      if (st == "\"") { if (c == "\"") st = ""; cur = cur c; continue }
      if (c == "$" && substr(args, i + 1, 1) == "(") { depth++; cur = cur "$("; i++; continue }
      if (depth > 0) { if (c == ")") depth--; cur = cur c; continue }
      if (c == "\047" || c == "\"") { st = c; cur = cur c; continue }
      if (c ~ /[[:space:]]/) { if (cur != "") { W[++n] = cur; cur = "" } continue }
      cur = cur c
    }
    if (cur != "") W[++n] = cur
    return n
  }
  function operand_kind(op,   b, v) {
    b = op; gsub(/["\047]/, "", b)
    if (b ~ /^-/) return "group"
    if (b ~ /PPID|ppid/) return "ancestry"
    if (match(b, /\$\(/)) return subst_kind(substr(b, RSTART + 2))
    if (b ~ /`/) { sub(/^[^`]*`/, "", b); return subst_kind(b) }
    if (b ~ /^\$\$$/ || b ~ /^\$\{\$\}$/) return "self"
    if (b ~ /^\$\{?[0-9@*]/) return "param"
    if (match(b, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
      v = substr(b, RSTART, RLENGTH); sub(/^\$\{?/, "", v)
      return lookup(v, 0)
    }
    return "literal"
  }
  function shell_form(args,   n, i, w, form, first) {
    n = words(args)
    i = 1; first = 1
    while (i <= n) {
      w = W[i]; gsub(/["\047]/, "", w)
      if (w == "--") { i++; break }
      if (w == "-l" || w == "-L") return "list"
      if (w == "-s" || w == "-n") { if (W[i + 1] ~ /^["\047]?0["\047]?$/) return "probe"; i += 2; first = 0; continue }
      if (first && w ~ /^-/) { if (w == "-0") return "probe"; i++; first = 0; continue }
      break
    }
    if (i > n) return "none"
    form = ""
    for (; i <= n; i++) {
      if (W[i] ~ /^[0-9]*>/) break
      form = pick(form, operand_kind(W[i]))
    }
    return form
  }
  function perl_form(rest,   a, n, i, k, s, form) {
    s = rest; sub(/^[[:space:]]*\(?[[:space:]]*/, "", s)
    n = split(s, a, ",")
    if (a[1] ~ /^["\047]?0["\047]?[[:space:]]*$/) return "probe"
    form = "perl"
    for (i = 2; i <= n; i++) {
      k = trim(a[i]); sub(/^\(/, "", k)
      if (k ~ /^-/ || k ~ /[?:][[:space:]]*-\$/) form = "group"
    }
    return form
  }
  function computed(form) { return form ~ /^(ancestry|group|name|cmdline|pidfile|read|subst)$/ }
  function what(form) {
    if (form == "group") return "a process group"
    if (form == "name") return "a process found by name or pattern"
    if (form == "cmdline") return "a process found by its command line"
    if (form == "ancestry") return "a process found through the process tree"
    if (form == "pidfile" || form == "read") return "a pid read from a file"
    return "a pid taken from another command'"'"'s output"
  }
  function report(text, file, line, body) { printf "%s:%d: %s: %s\n", file, line, text, body }
  function finding(form, line) {
    if (computed(form)) report("a signal to " what(form) " outside the guarded helper", FILENAME, FNR, line)
  }
  function reads_parentage(line) {
    return line ~ /PPID|ppid|getppid|\/proc\/[^[:space:]]*\/(stat|status)([^[:alnum:]_]|$)/
  }
  function signals_only_self(rest) {
    return rest ~ /^([[:space:]]+-[[:alnum:]]+)*[[:space:]]+"?\\?\$\\?\$"?([^[:alnum:]_]|$)/
  }
  # Every signal send on the line; sets SENDS (any send) and NOT_SELF (one
  # that is not only to $$) and reports each computed target.
  function scan(line,   p, word, lead, wpos, wname, rest, pre, f, r) {
    SENDS = 0; NOT_SELF = 0; p = 1
    while (match(substr(line, p), WORD_RE)) {
      word = substr(line, p + RSTART - 1, RLENGTH)
      lead = (word ~ ("^(" PK "|" KA "|" sig ")")) ? 0 : 1
      wpos = p + RSTART - 1 + lead
      wname = substr(word, 1 + lead); sub(/[^A-Za-z]+$/, "", wname)
      rest = substr(line, wpos + length(wname))
      p = wpos + length(wname)
      if (wname == sig && rest ~ /^[[:space:]]*\(?[[:space:]]*(["\047]?-?[A-Z0-9]+["\047]?|\$[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*,/) {
        f = perl_form(rest)
        if (f != "probe") { SENDS = 1; NOT_SELF = 1; finding(f, line) }
        continue
      }
      if (!command_position(line, wpos)) continue
      pre = trim(substr(line, 1, wpos - 1))
      if (wname != sig || pre ~ /xargs$/) { SENDS = 1; NOT_SELF = 1; finding("name", line); continue }
      f = shell_form(cut_args(rest))
      if (f == "probe" || f == "list" || f == "none") continue
      SENDS = 1
      if (!signals_only_self(rest)) NOT_SELF = 1
      finding(f, line)
    }
    if (match(line, ("os\\." sig "pg\\("))) {
      r = substr(line, RSTART + RLENGTH)
      if (r !~ /^[^,]*,[[:space:]]*0[[:space:]]*\)/) { SENDS = 1; NOT_SELF = 1; finding("group", line) }
    }
    if (match(line, ("process\\." sig "\\("))) {
      r = substr(line, RSTART + RLENGTH)
      if (r ~ /^[[:space:]]*-/ && r !~ /^[^,]*,[[:space:]]*0[[:space:]]*\)/) { SENDS = 1; NOT_SELF = 1; finding("group", line) }
    }
  }
  function track(line,   d) {
    if (in_doc) {
      body = line
      if (strip) sub(/^\t+/, "", body)
      if (body == delim) { in_doc = 0; scope = saved_scope; return 1 }
      return 0
    }
    if (line ~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)/) {
      d = line; sub(/^[[:space:]]*(function[[:space:]]+)?/, "", d); sub(/[[:space:]]*\(.*/, "", d)
      scope = "fn:" d
    } else if (line ~ /^}/) scope = "global"
    return 0
  }
  function open_doc(line,   d) {
    if (is_comment(line) || !match(line, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) return
    d = substr(line, RSTART, RLENGTH)
    strip = (d ~ /^<<-/)
    sub(/^<<-?[[:space:]]*/, "", d)
    gsub(/["\047]/, "", d)
    delim = d; in_doc = 1; saved_scope = scope; scope = "doc" FNR
    doc_start = FNR; doc_signal = 0; doc_parent = 0; doc_text = ""
  }
  BEGIN {
    PK = "p" sig; KA = sig "all"
    WORD_RE = "(^|[^A-Za-z0-9_.$>-])(" PK "|" KA "|" sig ")([^A-Za-z0-9_-]|$)"
  }
  FNR == 1 {
    if (FILENAME == prev && pass == 1) pass = 2; else { pass = 1; split("", kinds) }
    prev = FILENAME; in_doc = 0; scope = "global"
  }
  {
    was_doc = in_doc
    if (track($0)) {
      if (pass == 2 && doc_signal && doc_parent)
        report("a stand-in that reads parentage (line " doc_parent ") and signals (line " doc_signal ")", FILENAME, doc_start, doc_text)
      next
    }
  }
  pass == 1 { if (!is_comment($0)) collect($0); if (!in_doc) open_doc($0); next }
  {
    line = $0
    if (!is_comment(line)) {
      if (index(line, shim)) report("uses the removed crash-inject shim", FILENAME, FNR, line)
      scan(line)
      if (SENDS && NOT_SELF && reads_parentage(line)) report("a signal and a parentage read on one line", FILENAME, FNR, line)
      if (was_doc) {
        if (!doc_signal && SENDS && NOT_SELF) { doc_signal = FNR; doc_text = line }
        if (!doc_parent && reads_parentage(line)) doc_parent = FNR
      }
    }
    if (!in_doc) open_doc(line)
  }
' "${files[@]}")

if [ -n "$findings" ]; then
  printf 'not ok - a test signals a computed target outside the guarded helper:\n%s\n' "$findings" >&2
  exit 1
fi
printf 'ok - no test in %s file(s) signals a computed target outside the guarded helper\n' "$checked"
