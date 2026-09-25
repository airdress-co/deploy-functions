#!/usr/bin/env bash
# Download the airdress CLI, verify it against cli-digests.txt in this
# repository, and put it on PATH for the steps that follow.
#
# Fails closed: a version or platform with no pinned digest, a failed
# download, or a digest that does not match, all stop the job before the
# binary is ever run.
#
# Environment:
#   CLI_VERSION          the release to install, e.g. v0.1.0-alpha.23
#   ACTION_PATH          this Action's checkout (GITHUB_ACTION_PATH)
#   RUNNER_OS, RUNNER_ARCH, RUNNER_TEMP, GITHUB_PATH   set by the runner
#   AIRDRESS_CLI_BASE_URL  optional; where releases are served from. The
#                        digest check applies whatever the source.
set -euo pipefail

die() {
  echo "::error title=airdress CLI not installed::$*" >&2
  exit 1
}

: "${CLI_VERSION:?CLI_VERSION is not set}"
: "${ACTION_PATH:?ACTION_PATH is not set}"
: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"

base_url="${AIRDRESS_CLI_BASE_URL:-https://downloads.airdress.co/airdress-cli}"
digests="$ACTION_PATH/cli-digests.txt"
[[ -f "$digests" ]] || die "$digests is missing"

case "${RUNNER_OS:-}/${RUNNER_ARCH:-}" in
  Linux/X64) platform=linux-amd64 ;;
  Linux/ARM64) platform=linux-arm64 ;;
  macOS/X64) platform=darwin-amd64 ;;
  macOS/ARM64) platform=darwin-arm64 ;;
  Windows/X64) platform=windows-amd64 ;;
  *) die "no airdress CLI build for runner ${RUNNER_OS:-?}/${RUNNER_ARCH:-?}" ;;
esac

exe=""
[[ "$platform" == windows-* ]] && exe=".exe"
asset="airdress-${platform}${exe}"

# The one pinned digest for this version and platform; exactly one line.
expected="$(awk -v v="$CLI_VERSION" -v p="$platform" \
  '$0 !~ /^[[:space:]]*#/ && $1 == v && $2 == p { print $3 }' "$digests")"
count="$(printf '%s' "$expected" | grep -c . || true)"
if [[ "$count" -ne 1 ]]; then
  die "cli-digests.txt pins no single digest for $CLI_VERSION $platform (found $count); pick a version it lists, or add its line after hashing the binary yourself"
fi
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "the pinned digest for $CLI_VERSION $platform is not a SHA-256"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

dir="$RUNNER_TEMP/airdress-cli/$CLI_VERSION"
bin="$dir/airdress${exe}"
mkdir -p "$dir"

if [[ -f "$bin" && "$(sha256_of "$bin")" == "$expected" ]]; then
  echo "airdress $CLI_VERSION ($platform) already installed and verified"
else
  tmp="$(mktemp "$dir/download.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  url="$base_url/$CLI_VERSION/$asset"
  echo "downloading $url"
  curl --fail --silent --show-error --location --retry 3 --proto '=https' \
    --output "$tmp" "$url" || die "could not download $url"
  actual="$(sha256_of "$tmp")"
  if [[ "$actual" != "$expected" ]]; then
    die "$asset for $CLI_VERSION has SHA-256 $actual, but cli-digests.txt pins $expected; refusing to run it"
  fi
  chmod 0755 "$tmp"
  mv -f "$tmp" "$bin"
  trap - EXIT
  echo "verified $asset $CLI_VERSION: sha256 $actual"
fi

echo "$dir" >>"${GITHUB_PATH:?GITHUB_PATH is not set}"
"$bin" --version
