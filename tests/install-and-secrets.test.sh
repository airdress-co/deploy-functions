#!/usr/bin/env bash
# scripts/install-cli.sh and scripts/write-secrets.sh, run as the Action
# runs them. install-cli.sh downloads the real release, so this needs the
# network; it never talks to an operator.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

version="$(awk '$0 !~ /^#/ && NF == 3 { v = $1 } END { print v }' "$root/cli-digests.txt")"
[[ -n "$version" ]] || fail "cli-digests.txt lists no version"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) os=Linux arch=X64 ;;
  Linux/aarch64) os=Linux arch=ARM64 ;;
  Darwin/x86_64) os=macOS arch=X64 ;;
  Darwin/arm64) os=macOS arch=ARM64 ;;
  *) fail "no test for $(uname -s)/$(uname -m)" ;;
esac

install() {
  # install <action path> <runner temp> [version]; sets $out and $code.
  set +e
  out="$(env CLI_VERSION="${3:-$version}" ACTION_PATH="$1" RUNNER_TEMP="$2" \
    RUNNER_OS="$os" RUNNER_ARCH="$arch" GITHUB_PATH="$2/path" \
    bash "$root/scripts/install-cli.sh" 2>&1)"
  code=$?
  set -e
}

# --- the pinned release installs, verified, onto GITHUB_PATH -------------
mkdir -p "$work/good"
install "$root" "$work/good"
[[ $code -eq 0 ]] || fail "install exited $code: $out"
grep -q "^verified " <<<"$out" || fail "no verification line: $out"
bindir="$(cat "$work/good/path")"
"$bindir/airdress" --version | grep -qF "${version}" || fail "wrong binary on PATH"
echo "ok - $version installs, verified against cli-digests.txt"

# --- a digest that does not match refuses the binary ---------------------
mkdir -p "$work/tampered/action" "$work/tampered/tmp"
sed -E "s/^($version [a-z0-9-]+ +)[0-9a-f]{64}$/\1$(printf '0%.0s' {1..64})/" \
  "$root/cli-digests.txt" >"$work/tampered/action/cli-digests.txt"
install "$work/tampered/action" "$work/tampered/tmp"
[[ $code -ne 0 ]] || fail "a wrong digest was accepted"
grep -q "refusing to run it" <<<"$out" || fail "no refusal: $out"
[[ ! -e "$work/tampered/tmp/path" ]] || fail "a refused binary reached PATH"
[[ -z "$(find "$work/tampered/tmp/airdress-cli" -name 'airdress*' -type f)" ]] ||
  fail "a refused binary was left on disk"
echo "ok - a digest mismatch is refused, and nothing reaches PATH"

# --- a version with no pinned digest is refused before any download -----
mkdir -p "$work/unpinned"
install "$root" "$work/unpinned" v0.0.0-not-pinned
{ [[ $code -ne 0 ]] && grep -q "pins no single digest" <<<"$out"; } || fail "unpinned: $code $out"
echo "ok - a version cli-digests.txt does not list is refused"

# --- secrets: 0600 files in a 0700 directory, masked ---------------------
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
mkdir -p "$work/secrets"
: >"$work/secrets/output"
out="$(MACHINE_KEY="secret-machine-key" MACHINE_ENROLLMENT='{"machine_id":"m"}' \
  SIGNING_KEY="$(printf 'ab%.0s' {1..32})" RUNNER_TEMP="$work/secrets" \
  GITHUB_OUTPUT="$work/secrets/output" bash "$root/scripts/write-secrets.sh")"
grep -qx "::add-mask::secret-machine-key" <<<"$out" || fail "machine key not masked"
grep -qx "::add-mask::$(printf 'ab%.0s' {1..32})" <<<"$out" || fail "signing key not masked"
key="$(sed -n 's/^machine-key=//p' "$work/secrets/output")"
seed="$(sed -n 's/^signing-key=//p' "$work/secrets/output")"
dir="$(sed -n 's/^dir=//p' "$work/secrets/output")"
[[ "$(mode "$dir")" == 700 ]] || fail "dir mode $(mode "$dir")"
for f in "$key" "$key.json" "$seed"; do
  [[ "$(mode "$f")" == 600 ]] || fail "$f mode $(mode "$f")"
done
[[ "$(cat "$key")" == "secret-machine-key" ]] || fail "key contents"
[[ "$(cat "$key.json")" == '{"machine_id":"m"}' ]] || fail "enrollment beside the key"
if grep -v "::add-mask::" <<<"$out" | grep -q "secret-machine-key"; then fail "a secret was printed"; fi
echo "ok - secrets are written 0600 in a 0700 directory, and masked"

set +e
out="$(MACHINE_KEY="" MACHINE_ENROLLMENT="x" SIGNING_KEY=" " RUNNER_TEMP="$work/secrets" \
  GITHUB_OUTPUT="$work/secrets/output" bash "$root/scripts/write-secrets.sh" 2>&1)"
code=$?
set -e
{ [[ $code -ne 0 ]] && grep -q "machine-key signing-key" <<<"$out"; } || fail "empty secrets: $code $out"
echo "ok - an empty secret is refused, naming the input"
