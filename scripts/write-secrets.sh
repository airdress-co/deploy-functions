#!/usr/bin/env bash
# Write the three secrets to files only this user can read, under
# $RUNNER_TEMP, and mask them in the log.
#
# The CLI reads secrets from files (or from variables holding their
# contents), never from arguments, because a process listing shows
# arguments. The enrollment record is written beside the key as
# `<key>.json`, which is where the CLI looks for it.
#
# Environment:
#   MACHINE_KEY          the machine key, as `airdress-operator machine enroll` wrote it
#   MACHINE_ENROLLMENT   its enrollment record (the `<key>.json` beside it)
#   SIGNING_KEY          the Ed25519 source-signing seed, 64 hex characters
#   RUNNER_TEMP, GITHUB_OUTPUT   set by the runner
#
# Outputs: dir, machine-key, signing-key (paths, not contents).
set -euo pipefail

die() {
  echo "::error title=airdress secrets::$*" >&2
  exit 1
}

: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"

missing=()
[[ -n "${MACHINE_KEY//[[:space:]]/}" ]] || missing+=(machine-key)
[[ -n "${MACHINE_ENROLLMENT//[[:space:]]/}" ]] || missing+=(machine-enrollment)
[[ -n "${SIGNING_KEY//[[:space:]]/}" ]] || missing+=(signing-key)
if ((${#missing[@]})); then
  die "empty input(s): ${missing[*]}. Store them as repository or environment secrets and pass them to the Action"
fi

# Mask every non-blank line of a secret before anything could print it.
mask() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "${line//[[:space:]]/}" ]] && echo "::add-mask::$line"
  done <<<"$1"
}
mask "$MACHINE_KEY"
mask "$SIGNING_KEY"

umask 077
dir="$(mktemp -d "$RUNNER_TEMP/airdress-secrets.XXXXXX")"
chmod 0700 "$dir"

write_private() {
  # $1 path, $2 contents. Created 0600 by the umask; chmod in case the
  # file system ignores it.
  printf '%s\n' "$2" >"$1"
  chmod 0600 "$1"
}
write_private "$dir/machine.key" "$MACHINE_KEY"
write_private "$dir/machine.key.json" "$MACHINE_ENROLLMENT"
write_private "$dir/signing.key" "$SIGNING_KEY"

{
  echo "dir=$dir"
  echo "machine-key=$dir/machine.key"
  echo "signing-key=$dir/signing.key"
} >>"$GITHUB_OUTPUT"
echo "wrote the machine key, its enrollment record and the signing key to $dir (mode 0600)"
