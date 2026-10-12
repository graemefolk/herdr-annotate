#!/usr/bin/env bash
# The native Lite fetcher: local override, idempotence, and the two fatal inputs. Unlike the
# plannotator-tui fetcher, a failure here is fatal: the annotation tools are the binary.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
plugin_root="$test_root/plugin root with spaces"
source_root="$test_root/source binary with spaces"
mkdir -p "$plugin_root/scripts" "$plugin_root/bin" "$source_root"
cp "$repository_root/scripts/fetch-herdr-annotate.sh" "$plugin_root/scripts/"
cp "$repository_root/herdr-annotate.version" "$plugin_root/"
version="$(tr -d '[:space:]' < "$repository_root/herdr-annotate.version")"

source_binary="$source_root/herdr-annotate local"
cat > "$source_binary" <<SOURCE
#!/usr/bin/env sh
printf 'herdr-annotate $version\n'
SOURCE
chmod +x "$source_binary"
printf 'old destination' > "$plugin_root/bin/herdr-annotate.exe"
chmod +x "$plugin_root/bin/herdr-annotate.exe"
printf 'old-version' > "$plugin_root/bin/herdr-annotate.version"

HERDR_ANNOTATE_BIN="$source_binary" bash "$plugin_root/scripts/fetch-herdr-annotate.sh"
cmp "$source_binary" "$plugin_root/bin/herdr-annotate.exe"
test "$(cat "$plugin_root/bin/herdr-annotate.version")" = "$version"
test ! -e "$plugin_root/bin/herdr-annotate"
test "$("$plugin_root/bin/herdr-annotate.exe" --version)" = "herdr-annotate $version"

output="$(bash "$plugin_root/scripts/fetch-herdr-annotate.sh")"
case "$output" in
  *"already installed"*) ;;
  *) echo "idempotent fetch did not short-circuit: $output" >&2; exit 1 ;;
esac

# A release served without the network: curl is replaced on PATH by a stub that answers from
# $release_root by file name and logs every URL it was asked for.
release_root="$test_root/release with spaces"
fake_path="$test_root/fake path"
mkdir -p "$release_root" "$fake_path"
cat > "$fake_path/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--retry) [ "$1" = -o ] && out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
cp "$FAKE_RELEASE_ROOT/${url##*/}" "$out"
STUB
chmod +x "$fake_path/curl"
curl_log="$test_root/curl.log"
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
publish() {
  : > "$release_root/SHA256SUMS"
  for target in aarch64-apple-darwin x86_64-apple-darwin x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    cp "$1" "$release_root/herdr-annotate-$target"
    printf '%s  %s\n' "$(sha256 "$1")" "herdr-annotate-$target" >> "$release_root/SHA256SUMS"
  done
}
fetch_offline() {
  : > "$curl_log"
  PATH="$fake_path:$PATH" FAKE_CURL_LOG="$curl_log" FAKE_RELEASE_ROOT="$release_root" \
    bash "$plugin_root/scripts/fetch-herdr-annotate.sh"
}
# A binary built for the other OS, as a plugin directory synced from another machine carries:
# this host's kernel refuses to execute it.
install_foreign() {
  case "$(uname -s)" in Darwin) magic='\177ELF' ;; *) magic='\317\372\355\376' ;; esac
  printf '%b' "$magic"'\002\001\001\000\000\000\000\000\000\000\000\000' > "$1"
  chmod +x "$1"
}

release_binary="$test_root/release herdr-annotate"
cat > "$release_binary" <<RELEASE
#!/usr/bin/env sh
printf 'herdr-annotate $version\n'
# release fixture
RELEASE
chmod +x "$release_binary"
publish "$release_binary"

# A matching stamp over a binary that cannot run here is not "already installed": the verified
# release replaces it.
install_foreign "$plugin_root/bin/herdr-annotate.exe"
output="$(fetch_offline)"
case "$output" in
  *"already installed"*) echo "an unrunnable binary short-circuited: $output" >&2; exit 1 ;;
esac
cmp "$release_binary" "$plugin_root/bin/herdr-annotate.exe"
test "$(cat "$plugin_root/bin/herdr-annotate.version")" = "$version"
grep -qx "https://github.com/plannotator/herdr-annotate/releases/download/rust-lite-v$version/SHA256SUMS" "$curl_log"

output="$(fetch_offline)"
case "$output" in
  *"already installed"*) ;;
  *) echo "a runnable reinstalled binary did not short-circuit: $output" >&2; exit 1 ;;
esac
test ! -s "$curl_log"

# The fallthrough still verifies: a checksum mismatch stays fatal and leaves bin/ alone.
install_foreign "$plugin_root/bin/herdr-annotate.exe"
cp "$plugin_root/bin/herdr-annotate.exe" "$test_root/foreign"
sed 's/^[0-9a-f]*/0000000000000000000000000000000000000000000000000000000000000000/' \
  "$release_root/SHA256SUMS" > "$release_root/SHA256SUMS.bad"
mv "$release_root/SHA256SUMS.bad" "$release_root/SHA256SUMS"
if fetch_offline >/dev/null 2>"$test_root/mismatch.err"; then
  echo "a checksum mismatch exited successfully" >&2; exit 1
fi
grep -q "sha256 mismatch" "$test_root/mismatch.err"
cmp "$test_root/foreign" "$plugin_root/bin/herdr-annotate.exe"

# Put a runnable binary back for the remaining cases.
publish "$release_binary"
fetch_offline >/dev/null

before="$(cat "$plugin_root/bin/herdr-annotate.exe")"
if HERDR_ANNOTATE_BIN="$test_root/missing override" bash "$plugin_root/scripts/fetch-herdr-annotate.sh" 2>"$test_root/missing.err"; then
  echo "a missing local override exited successfully" >&2; exit 1
fi
grep -q "HERDR_ANNOTATE_BIN is not executable" "$test_root/missing.err"
test "$(cat "$plugin_root/bin/herdr-annotate.exe")" = "$before"

printf '' > "$plugin_root/herdr-annotate.version"
if bash "$plugin_root/scripts/fetch-herdr-annotate.sh" 2>"$test_root/empty.err"; then
  echo "an empty version pin exited successfully" >&2; exit 1
fi
grep -q "herdr-annotate.version is empty" "$test_root/empty.err"
test "$(cat "$plugin_root/bin/herdr-annotate.exe")" = "$before"
