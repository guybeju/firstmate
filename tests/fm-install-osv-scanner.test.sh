#!/usr/bin/env bash
# fm-install-osv-scanner.test.sh - the pinned osv-scanner installer selects the
# official release binary and its pinned checksum per OS/arch, retries a
# transient download failure, and refuses a wrong checksum or an unsupported
# platform. PATH stubs stand in for uname, curl, the hashers, and sleep, so
# nothing is fetched and the installed "binary" is a stub that prints a version.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-osv-scanner.sh"
REQUIRED=$("$INSTALLER" --required-version)

# Official sha256 values from osv-scanner_SHA256SUMS on the v2.7.1 release
# (https://github.com/google/osv-scanner/releases/tag/v2.7.1). Tests compare
# installer behavior against these published digests, not script source.
OSV_SHA_LINUX_AMD64=fb7dab19a8bd9bbe5c3189f09d4b7ee1820c9553a23bac202648a56efd2f6ee8
OSV_SHA_LINUX_ARM64=983d22fbad9724514e3fcc6acc83b5fa64c5ffa6b0d9f510028f22c1b223ff81
OSV_SHA_DARWIN_AMD64=b8420d5485ba792626315f1bf9a5a2046e971d38eea75bf9090c38852dbc3b1b
OSV_SHA_DARWIN_ARM64=b22c02877a811c8f78956e8643efa554932b7378f590d13f8e97d4e9448a29f3

stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

# The downloaded "binary" is a script that prints a version, so the installer's
# final version check runs without fetching anything.
stub_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "${CURL_COUNT:-}" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
[ -z "${CURL_COUNT:-}" ] || printf '%s\n' "$count" > "$CURL_COUNT"
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out=$2
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[ -z "${CURL_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$CURL_URL_LOG"
fail_until=${CURL_FAIL_UNTIL:-0}
[ "$count" -gt "$fail_until" ] || exit 22
printf '#!/usr/bin/env bash\nprintf "osv-scanner version: stub\\n"\n' > "$out"
exit 0
SH
  chmod +x "$fakebin/curl"
}

stub_hasher() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
self=${0##*/}
if [ -n "${HASHER_LOG:-}" ]; then
  printf '%s\n' "$self $*" >> "$HASHER_LOG"
fi
file=$1
if [ "$self" = shasum ]; then
  algo=
  file=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -a)
        algo=$2
        shift 2
        ;;
      *)
        file=$1
        shift
        ;;
    esac
  done
  [ "$algo" = 256 ] || exit 1
fi
printf '%s  %s\n' "${SHA256_STUB_HASH:?}" "$file"
SH
  chmod +x "$fakebin/$name"
}

stub_sleep() {
  local fakebin=$1
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/sleep"
  chmod +x "$fakebin/sleep"
}

stub_all() {
  local fakebin=$1
  stub_uname "$fakebin"
  stub_curl "$fakebin"
  stub_hasher "$fakebin" sha256sum
  stub_sleep "$fakebin"
}

test_prints_required_version() {
  case "$REQUIRED" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "--required-version printed '$REQUIRED', not one exact x.y.z version" ;;
  esac
  pass "osv-scanner installer prints one exact required version"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-osv-scanner-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  stub_all "$fakebin"

  out=$(CURL_COUNT="$tmp/curl-count" CURL_FAIL_UNTIL=3 \
    SHA256_STUB_HASH="$OSV_SHA_LINUX_AMD64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 4 ] || fail "installer did not recover after three failed downloads"
  assert_contains "$out" "download attempt 3 failed; retrying" "installer did not disclose its third retry"
  [ -x "$destination/osv-scanner" ] || fail "installer did not install osv-scanner after retrying"
  pass "osv-scanner installer retries a transient download failure"
}

test_installer_selects_platform_asset_url_and_checksum() {
  local tmp fakebin destination out url_log uname_s uname_m asset sha
  tmp=$(fm_test_tmproot fm-osv-scanner-platform)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/curl-url.log"
  stub_all "$fakebin"

  while IFS=$'\t' read -r uname_s uname_m asset sha; do
    [ -n "$uname_s" ] || continue
    rm -rf "$destination"
    : > "$url_log"
    out=$(CURL_URL_LOG="$url_log" SHA256_STUB_HASH="$sha" \
      FM_TEST_UNAME_S="$uname_s" FM_TEST_UNAME_M="$uname_m" \
      PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
      || fail "installer failed for ${uname_s}/${uname_m}"$'\n'"$out"
    [ "$(cat "$url_log")" = \
      "https://github.com/google/osv-scanner/releases/download/v${REQUIRED}/${asset}" ] \
      || fail "installer used the wrong URL for ${uname_s}/${uname_m}: $(cat "$url_log")"
    [ -x "$destination/osv-scanner" ] || fail "installer did not install osv-scanner for ${uname_s}/${uname_m}"
    assert_contains "$out" "osv-scanner version" \
      "installer did not run the installed binary's version check for ${uname_s}/${uname_m}"
  done <<EOF
Linux	x86_64	osv-scanner_linux_amd64	$OSV_SHA_LINUX_AMD64
Linux	amd64	osv-scanner_linux_amd64	$OSV_SHA_LINUX_AMD64
Linux	aarch64	osv-scanner_linux_arm64	$OSV_SHA_LINUX_ARM64
Linux	arm64	osv-scanner_linux_arm64	$OSV_SHA_LINUX_ARM64
Darwin	x86_64	osv-scanner_darwin_amd64	$OSV_SHA_DARWIN_AMD64
Darwin	amd64	osv-scanner_darwin_amd64	$OSV_SHA_DARWIN_AMD64
Darwin	arm64	osv-scanner_darwin_arm64	$OSV_SHA_DARWIN_ARM64
Darwin	aarch64	osv-scanner_darwin_arm64	$OSV_SHA_DARWIN_ARM64
EOF
  pass "osv-scanner installer selects the official asset, URL, and checksum per OS/arch"
}

test_installer_rejects_wrong_checksum() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-osv-scanner-badsum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  stub_all "$fakebin"

  rc=0
  out=$(SHA256_STUB_HASH=0000000000000000000000000000000000000000000000000000000000000000 \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted a wrong checksum"$'\n'"$out"
  assert_contains "$out" "checksum mismatch" "installer did not report a checksum mismatch"
  assert_contains "$out" "osv-scanner_linux_amd64" "mismatch did not name the selected asset"
  assert_contains "$out" "$OSV_SHA_LINUX_AMD64" "mismatch did not name the pinned linux/amd64 checksum"
  [ ! -e "$destination/osv-scanner" ] || fail "installer installed osv-scanner after a checksum mismatch"
  pass "osv-scanner installer rejects a wrong checksum"
}

test_installer_falls_back_to_shasum() {
  local tmp fakebin destination out hasher_log tool
  tmp=$(fm_test_tmproot fm-osv-scanner-shasum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  for tool in bash mktemp rm awk mkdir install cat chmod; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  stub_uname "$fakebin"
  stub_curl "$fakebin"
  stub_hasher "$fakebin" shasum
  stub_sleep "$fakebin"

  : > "$hasher_log"
  out=$(HASHER_LOG="$hasher_log" SHA256_STUB_HASH="$OSV_SHA_LINUX_AMD64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not fall back to shasum -a 256"$'\n'"$out"
  assert_grep 'shasum -a 256' "$hasher_log" "installer did not invoke shasum -a 256"
  [ -x "$destination/osv-scanner" ] || fail "installer did not install osv-scanner via shasum"
  pass "osv-scanner installer falls back to shasum -a 256 when sha256sum is absent"
}

test_installer_prefers_sha256sum_over_shasum() {
  local tmp fakebin destination hasher_log
  tmp=$(fm_test_tmproot fm-osv-scanner-sha256sum-pref)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"
  stub_all "$fakebin"
  stub_hasher "$fakebin" shasum

  : > "$hasher_log"
  HASHER_LOG="$hasher_log" SHA256_STUB_HASH="$OSV_SHA_LINUX_AMD64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" >/dev/null \
    || fail "installer failed when both hashers were present"
  assert_grep 'sha256sum' "$hasher_log" "installer did not prefer sha256sum"
  if grep -q 'shasum' "$hasher_log"; then
    fail "installer invoked shasum even though sha256sum was present"$'\n'"$(cat "$hasher_log")"
  fi
  pass "osv-scanner installer prefers sha256sum when both hashers are present"
}

test_installer_rejects_unsupported_platform() {
  local tmp fakebin destination out rc url_log
  tmp=$(fm_test_tmproot fm-osv-scanner-unsupported)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/curl-url.log"
  stub_uname "$fakebin"
  stub_curl "$fakebin"

  : > "$url_log"
  rc=0
  out=$(CURL_URL_LOG="$url_log" FM_TEST_UNAME_S=FreeBSD FM_TEST_UNAME_M=amd64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported OS"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not name the unsupported platform"
  assert_contains "$out" "FreeBSD-amd64" "installer did not report the detected OS/arch"

  rc=0
  out=$(CURL_URL_LOG="$url_log" FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=ppc64le \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported architecture"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not reject linux/ppc64le"
  [ ! -s "$url_log" ] || fail "installer downloaded on an unsupported platform: $(cat "$url_log")"
  pass "osv-scanner installer rejects an unsupported OS or architecture without downloading"
}

test_prints_required_version
test_installer_retries_transient_download_failure
test_installer_selects_platform_asset_url_and_checksum
test_installer_rejects_wrong_checksum
test_installer_falls_back_to_shasum
test_installer_prefers_sha256sum_over_shasum
test_installer_rejects_unsupported_platform
