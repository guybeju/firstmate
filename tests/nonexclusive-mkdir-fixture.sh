#!/usr/bin/env bash
# tests/nonexclusive-mkdir-fixture.sh - the shared fake for mkdir builds that report
# success to a caller whose directory another caller created. tests/lib.sh
# loads it; a suite that does not load tests/lib.sh sources it directly.

# fm_fake_nonexclusive_mkdir <fakebin>
# Drops a mkdir that reports success when a directory it was asked to create
# already exists, as uutils coreutils 0.10.0 does for a racer that lost the
# race to create it. The fake does it on every call, not only inside a race
# window, so a claim, lock, or once-only marker that trusts mkdir's exit
# status admits a second winner deterministically. Any other failure keeps
# the real mkdir's status and message.
# With FM_FAKE_MKDIR_BARRIER=<dir> and FM_FAKE_MKDIR_BARRIER_MATCH=<glob>, a
# call naming a matching path first waits (up to 10s) until
# FM_FAKE_MKDIR_BARRIER_PARTIES (default 2) such calls have arrived, so racers
# that check for the path before creating it all pass that check first.
fm_fake_nonexclusive_mkdir() {
  local fakebin=$1 real_mkdir
  real_mkdir=$(command -v mkdir) || return 1
  [ "$real_mkdir" != "$fakebin/mkdir" ] || return 1
  cat > "$fakebin/mkdir" <<SH
#!/usr/bin/env bash
operands=()
skip=0
ended=0
for arg in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  if [ "\$ended" = 0 ]; then
    case "\$arg" in
      --) ended=1; continue ;;
      -m) skip=1; continue ;;
      -*) continue ;;
    esac
  fi
  operands+=("\$arg")
done
if [ -n "\${FM_FAKE_MKDIR_BARRIER:-}" ] && [ -n "\${FM_FAKE_MKDIR_BARRIER_MATCH:-}" ]; then
  for arg in "\${operands[@]}"; do
    # shellcheck disable=SC2254 # The match variable is a glob by contract.
    case "\$arg" in
      \$FM_FAKE_MKDIR_BARRIER_MATCH)
        : > "\$FM_FAKE_MKDIR_BARRIER/arrived.\$\$"
        for _ in \$(seq 1 200); do
          arrivals=("\$FM_FAKE_MKDIR_BARRIER"/arrived.*)
          [ "\${#arrivals[@]}" -lt "\${FM_FAKE_MKDIR_BARRIER_PARTIES:-2}" ] || break
          sleep 0.05
        done
        break
        ;;
    esac
  done
fi
if err=\$("$real_mkdir" "\$@" 2>&1); then
  [ -z "\$err" ] || printf '%s\n' "\$err"
  exit 0
else
  status=\$?
fi
[ "\${#operands[@]}" -gt 0 ] || { printf '%s\n' "\$err" >&2; exit "\$status"; }
for arg in "\${operands[@]}"; do
  [ -d "\$arg" ] || { printf '%s\n' "\$err" >&2; exit "\$status"; }
done
exit 0
SH
  chmod +x "$fakebin/mkdir"
}
